import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/app_paths.dart';
import '../core/logger.dart';
import '../core/settings.dart';
import '../native/native_bridge.dart';
import 'install_progress.dart';
import 'proot_command.dart';
import 'rootfs_installer.dart';

/// Facade over the sandbox: binary discovery, installation and launching.
class LinuxEnvironment {
  LinuxEnvironment({
    required this.paths,
    required this.native,
    required this.device,
    required this.settings,
  });

  final AppPaths paths;
  final NativeBridge native;
  final DeviceInfo device;
  final AppSettings settings;

  ProotBinaries? _binaries;
  EnvironmentManifest? _manifest;

  /// Locates `proot` and its loader.
  ///
  /// Order matters:
  ///  1. `ApplicationInfo.nativeLibraryDir` — the only location Android 10+
  ///     lets an app `execve` from (SELinux `apk_data_file`).
  ///  2. `assets/proot/*` copied into app storage + chmod 0755 — the legacy
  ///     path that only works with `targetSdk <= 28`.
  Future<ProotBinaries> resolveBinaries({bool refresh = false}) async {
    final ProotBinaries? cached = _binaries;
    if (cached != null && !refresh) {
      return cached;
    }

    String? prootPath;
    String? loaderPath;
    String source = 'missing';
    bool prootExecutable = false;
    bool loaderExecutable = false;

    final String nativeDir = device.nativeLibraryDir;
    if (nativeDir.isNotEmpty) {
      final File nativeProot = File('$nativeDir/libproot.so');
      final File nativeLoader = File('$nativeDir/libproot-loader.so');
      if (await nativeProot.exists()) {
        prootPath = nativeProot.path;
        source = 'nativeLibraryDir';
        prootExecutable = await native.isExecutable(nativeProot.path);
        if (await nativeLoader.exists()) {
          loaderPath = nativeLoader.path;
          loaderExecutable = await native.isExecutable(nativeLoader.path);
        }
      }
    }

    // Fallback only when the native-library copy is unusable.
    if (!prootExecutable) {
      final File? staged = await _stageAssetBinary(
        'assets/proot/proot-aarch64',
        File('${paths.binDir.path}/proot'),
      );
      if (staged != null) {
        prootPath = staged.path;
        source = 'assets';
        prootExecutable = await native.isExecutable(staged.path);
        final File? stagedLoader = await _stageAssetBinary(
          'assets/proot/proot-loader-aarch64',
          File('${paths.binDir.path}/proot-loader'),
        );
        if (stagedLoader != null) {
          loaderPath = stagedLoader.path;
          loaderExecutable = await native.isExecutable(stagedLoader.path);
        }
      }
    }

    final ProotBinaries result = ProotBinaries(
      prootPath: prootPath,
      loaderPath: loaderPath,
      source: source,
      prootExecutable: prootExecutable,
      loaderExecutable: loaderExecutable,
    );
    AppLogger.instance.log(
      'binaries: source=$source proot=$prootPath exec=$prootExecutable '
      'loader=$loaderPath loaderExec=$loaderExecutable',
    );
    _binaries = result;
    return result;
  }

  Future<File?> _stageAssetBinary(String assetKey, File target) async {
    try {
      final ByteData data = await rootBundle.load(assetKey);
      await target.parent.create(recursive: true);
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await native
          .applyFileModes(<FileModeEntry>[FileModeEntry(target.path, 0x1ED)]);
      AppLogger.instance.log('staged asset $assetKey -> ${target.path}');
      return target;
    } catch (error) {
      // Absent optional asset: not an error, the native-library copy is used.
      AppLogger.instance.log('asset $assetKey unavailable: $error');
      return null;
    }
  }

  Future<EnvironmentManifest?> readManifest({bool refresh = false}) async {
    final EnvironmentManifest? cached = _manifest;
    if (cached != null && !refresh) {
      return cached;
    }
    for (final File candidate in <File>[
      paths.environmentManifest,
      paths.installMarker
    ]) {
      try {
        if (!await candidate.exists()) {
          continue;
        }
        final Object? decoded = jsonDecode(await candidate.readAsString());
        if (decoded is Map<String, dynamic>) {
          final EnvironmentManifest manifest =
              EnvironmentManifest.fromJson(decoded);
          _manifest = manifest;
          return manifest;
        }
      } catch (error) {
        AppLogger.instance.log('could not read ${candidate.path}: $error');
      }
    }
    return null;
  }

  Future<EnvironmentStatus> inspect({bool refresh = false}) async {
    final ProotBinaries binaries = await resolveBinaries(refresh: refresh);
    final bool marker = await paths.installMarker.exists();
    final EnvironmentManifest? manifest = await readManifest(refresh: refresh);
    final bool guestShell =
        await File('${paths.rootfsDir.path}/bin/sh').exists();
    final bool bash = await File('${paths.rootfsDir.path}/bin/bash').exists();

    final List<DiagnosticEntry> diagnostics = <DiagnosticEntry>[
      DiagnosticEntry(
          'Device', '${device.model} · API ${device.sdkInt} · ${device.abi}'),
      DiagnosticEntry('App storage', paths.root),
      DiagnosticEntry(
        'PRoot binary',
        binaries.prootPath ?? 'not found',
        ok: binaries.prootExecutable,
        fatal: true,
      ),
      DiagnosticEntry('PRoot source', binaries.source,
          ok: binaries.source != 'missing'),
      DiagnosticEntry(
        'PROOT_LOADER',
        binaries.loaderPath ??
            (device.sdkInt >= 29
                ? 'missing — guest execve() will fail on Android 10+'
                : 'missing — legacy mode, PRoot extracts its own loader'),
        ok: binaries.hasLoader,
      ),
      DiagnosticEntry(
        'Root filesystem',
        marker ? '${manifest?.flavor ?? 'Linux'} (installed)' : 'not installed',
        ok: marker,
      ),
      DiagnosticEntry('/bin/sh', guestShell ? 'present' : 'missing',
          ok: guestShell),
      DiagnosticEntry(
          '/bin/bash', bash ? 'present' : 'absent (falls back to sh)',
          ok: true),
    ];

    return EnvironmentStatus(
      rootfsInstalled: marker && guestShell,
      binaries: binaries,
      diagnostics: diagnostics,
      manifest: manifest,
    );
  }

  Future<void> install({required InstallProgressCallback onProgress}) async {
    final ProotBinaries binaries = await resolveBinaries(refresh: true);
    if (!binaries.isUsable) {
      throw EnvironmentException(
        'Cannot install the Linux environment: ${binaries.prootPath == null ? 'no PRoot binary is bundled with this build.' : 'the bundled PRoot binary is not executable.'}',
        hint: EnvironmentStatus(
          rootfsInstalled: false,
          binaries: binaries,
          diagnostics: const <DiagnosticEntry>[],
          manifest: null,
        ).describeHint(device.sdkInt),
      );
    }
    await RootfsInstaller(paths: paths, native: native)
        .install(onProgress: onProgress);
    _manifest = null;
    await readManifest(refresh: true);
  }

  Future<LaunchSpec> buildLaunchSpec(ProotOptions options) async {
    final ProotBinaries binaries = await resolveBinaries();
    if (!binaries.isUsable) {
      throw const EnvironmentException(
        'The sandbox cannot start because PRoot is unavailable.',
        hint: 'Open Diagnostics for the binary paths and SELinux hints.',
      );
    }
    return ProotCommandBuilder(paths: paths, binaries: binaries).build(options);
  }

  /// The shell to boot the guest with.
  ///
  /// Precedence: explicit user choice → shell detected at install time
  /// (`/bin/bash` for Ubuntu, `/bin/sh` for Alpine) → posix sh.
  String defaultShell() {
    final String? override = settings.shellPath;
    if (override != null && override.isNotEmpty) {
      return override;
    }
    final String? recorded = _manifest?.shell;
    if (recorded != null && recorded.isNotEmpty) {
      return recorded;
    }
    return '/bin/sh';
  }

  /// Deletes the container but keeps `home/` and the user's settings.
  Future<void> resetRootfs() async {
    await paths.deleteRecursively(paths.rootfsDir);
    await paths.deleteRecursively(paths.installMarker);
    await paths.deleteRecursively(paths.environmentManifest);
    await paths.deleteRecursively(paths.stagedArchive);
    await paths.deleteRecursively(paths.stagedTar);
    _manifest = null;
    await paths.ensureLayout();
    AppLogger.instance.log('rootfs reset');
  }
}
