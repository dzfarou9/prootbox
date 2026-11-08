import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../core/app_paths.dart';
import '../core/logger.dart';
import '../native/native_bridge.dart';
import 'install_progress.dart';
import 'tar_extractor.dart';

/// First-launch installation of the Linux userland.
///
/// Pipeline:
///   1. read the bundled archive from the APK (`assets/rootfs/rootfs.tar.gz`)
///   2. stage it inside app storage (chunked, progress-aware)
///   3. streaming-gunzip into a plain tar
///   4. extract with symlinks/hardlinks/modes preserved
///   5. hand the mode table to Kotlin (`Os.chmod`) — Dart has no chmod
///   6. write the marker + manifest last, so a crash mid-install is retried
class RootfsInstaller {
  RootfsInstaller({required this.paths, required this.native});

  /// `.tar.gz` first: `dart:io` has a native gzip decoder, and both Alpine
  /// (`alpine-minirootfs-*-aarch64.tar.gz`) and Ubuntu Base ship gzip tars.
  static const List<String> assetCandidates = <String>[
    'assets/rootfs/rootfs.tar.gz',
    'assets/rootfs/rootfs.tar.xz',
  ];

  final AppPaths paths;
  final NativeBridge native;

  Future<void> install({required InstallProgressCallback onProgress}) async {
    if (await paths.installMarker.exists() &&
        await File('${paths.rootfsDir.path}/bin/sh').exists()) {
      onProgress(const InstallProgress(
        InstallPhase.ready,
        1,
        'Linux environment already installed',
      ));
      return;
    }

    onProgress(const InstallProgress(
      InstallPhase.preparing,
      0.01,
      'Creating private storage layout',
    ));

    // Remove a half-written rootfs from an interrupted install.
    await paths.deleteRecursively(paths.rootfsDir);
    await paths.ensureLayout();

    final _ArchiveAsset asset = await _loadArchiveAsset();
    AppLogger.instance.log(
      'installer: asset=${asset.key} bytes=${asset.bytes.length} format=${asset.format.name}',
    );

    bool succeeded = false;
    try {
      await _stageArchive(asset, onProgress);
      await _decompress(onProgress);

      onProgress(InstallProgress(
        InstallPhase.extracting,
        0.5,
        'Extracting ${asset.format == _ArchiveFormat.gzip ? 'gzip' : 'xz'} archive',
      ));

      final TarExtractor extractor = TarExtractor(destination: paths.rootfsDir);
      final TarExtractionResult result = await extractor.extract(
        paths.stagedTar,
        onProgress: (TarProgress progress) {
          onProgress(InstallProgress(
            InstallPhase.extracting,
            0.5 + 0.4 * progress.fraction,
            '${progress.entries} entries · ${_mb(progress.bytesProcessed)} / ${_mb(progress.totalBytes)}',
          ));
        },
      );

      onProgress(InstallProgress(
        InstallPhase.permissions,
        0.92,
        'Applying POSIX modes to ${result.modes.length} paths',
      ));
      await native.applyFileModes(result.modes);

      onProgress(const InstallProgress(
        InstallPhase.finalizing,
        0.96,
        'Writing DNS config and install manifest',
      ));
      await _finalize(asset, result);

      succeeded = true;
      onProgress(InstallProgress(
        InstallPhase.ready,
        1,
        'Installed ${result.files} files',
      ));
      AppLogger.instance.log(
        'installer: done files=${result.files} dirs=${result.directories} '
        'symlinks=${result.symlinks} hardlinks=${result.hardlinks} '
        'skipped=${result.skipped}',
      );
    } finally {
      await paths.deleteRecursively(paths.stagedArchive);
      await paths.deleteRecursively(paths.stagedTar);
      if (!succeeded) {
        // Never leave a half-extracted userland behind.
        await paths.deleteRecursively(paths.rootfsDir);
        await paths.ensureLayout();
      }
    }
  }

  Future<_ArchiveAsset> _loadArchiveAsset() async {
    Object? lastError;
    for (final String key in assetCandidates) {
      try {
        final ByteData data = await rootBundle.load(key);
        final Uint8List bytes =
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        if (bytes.length < 512) {
          lastError = 'asset $key is empty or truncated';
          continue;
        }
        final _ArchiveFormat format = _detectFormat(bytes);
        return _ArchiveAsset(key: key, bytes: bytes, format: format);
      } catch (error) {
        lastError = error;
      }
    }
    throw EnvironmentException(
      'No root filesystem is bundled with this build.',
      hint: 'Run scripts/build-rootfs.sh to download Alpine/Ubuntu ARM64 '
          'into assets/rootfs/, then rebuild the app. (Tried: '
          '${assetCandidates.join(', ')} — last error: $lastError)',
    );
  }

  static _ArchiveFormat _detectFormat(Uint8List bytes) {
    if (bytes.length > 3 &&
        bytes[0] == 0xFD &&
        bytes[1] == 0x37 &&
        bytes[2] == 0x7A &&
        bytes[3] == 0x58) {
      return _ArchiveFormat.xz;
    }
    return _ArchiveFormat.gzip;
  }

  Future<void> _stageArchive(
    _ArchiveAsset asset,
    InstallProgressCallback onProgress,
  ) async {
    const int chunkSize = 256 * 1024;
    final IOSink sink = paths.stagedArchive.openWrite();
    try {
      for (int offset = 0; offset < asset.bytes.length; offset += chunkSize) {
        final int end = math.min(offset + chunkSize, asset.bytes.length);
        sink.add(Uint8List.sublistView(asset.bytes, offset, end));
        await sink.flush();
        onProgress(InstallProgress(
          InstallPhase.readingArchive,
          0.03 + 0.22 * (end / asset.bytes.length),
          'Copied ${_mb(end)} of ${_mb(asset.bytes.length)} from APK assets',
        ));
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  Future<void> _decompress(InstallProgressCallback onProgress) async {
    if ((await _detectStagedFormat()) == _ArchiveFormat.xz) {
      throw const EnvironmentException(
        'This build bundles a .tar.xz rootfs, which cannot be decompressed.',
        hint: 'Re-generate the archive with scripts/build-rootfs.sh — it '
            'produces rootfs.tar.gz, which the Dart runtime decompresses '
            'natively. (There is no xz decoder in the Android runtime.)',
      );
    }

    final int totalCompressed = await paths.stagedArchive.length();
    int consumed = 0;
    int lastReportMs = 0;

    final Stream<List<int>> counted = paths.stagedArchive
        .openRead()
        .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (List<int> data, EventSink<List<int>> sink) {
        consumed += data.length;
        sink.add(data);
      },
    ));

    final IOSink sink = paths.stagedTar.openWrite();
    try {
      final Stream<List<int>> inflated = gzip.decoder.bind(counted);
      await for (final List<int> chunk in inflated) {
        sink.add(chunk);
        final int now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastReportMs > 80) {
          lastReportMs = now;
          final double fraction =
              totalCompressed == 0 ? 0 : consumed / totalCompressed;
          onProgress(InstallProgress(
            InstallPhase.decompressing,
            0.25 + 0.25 * (fraction > 1 ? 1 : fraction),
            'Inflating ${_mb(consumed)} of ${_mb(totalCompressed)}',
          ));
        }
      }
    } on FormatException catch (error) {
      throw EnvironmentException(
        'The bundled rootfs archive is not valid gzip data.',
        hint: 'Re-download it with scripts/build-rootfs.sh. ($error)',
      );
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  Future<_ArchiveFormat> _detectStagedFormat() async {
    final RandomAccessFile raf = await paths.stagedArchive.open();
    try {
      final Uint8List head = await raf.read(4);
      final bool isXz = head.length == 4 &&
          head[0] == 0xFD &&
          head[1] == 0x37 &&
          head[2] == 0x7A &&
          head[3] == 0x58;
      return isXz ? _ArchiveFormat.xz : _ArchiveFormat.gzip;
    } finally {
      await raf.close();
    }
  }

  Future<void> _finalize(
      _ArchiveAsset asset, TarExtractionResult result) async {
    final String rootfs = paths.rootfsDir.path;
    final bool shellPresent = await File('$rootfs/bin/sh').exists();
    if (!shellPresent) {
      throw const EnvironmentException(
        'Extraction completed but /bin/sh is missing — the archive is not a root filesystem.',
        hint: 'Point assets/rootfs/rootfs.tar.gz at an Alpine minirootfs or '
            'Ubuntu Base arm64 tarball.',
      );
    }

    final String flavor = await _detectFlavor(rootfs);
    final bool bash = await File('$rootfs/bin/bash').exists();

    // /root is normally bind-mounted to app storage, but create it so
    // `proot -w /root` works even if the bind is skipped.
    await Directory('$rootfs/root').create(recursive: true);

    // Android has no /etc/resolv.conf, and the guest needs DNS for
    // `apk add` / `apt-get` / `npm install`.
    await paths.resolvConf.writeAsString(
      'nameserver 1.1.1.1\nnameserver 8.8.8.8\n',
      flush: true,
    );

    await paths.homeDir.create(recursive: true);

    final EnvironmentManifest manifest = EnvironmentManifest(
      flavor: flavor,
      shell: bash ? '/bin/bash' : '/bin/sh',
      archive: asset.key.split('/').last,
      installedAt: DateTime.now().toUtc().toIso8601String(),
      files: result.files,
    );

    final String payload =
        const JsonEncoder.withIndent('  ').convert(manifest.toJson());
    await paths.environmentManifest.writeAsString(payload, flush: true);
    // Written last: its presence is the "installation is complete" signal.
    await paths.installMarker.writeAsString(payload, flush: true);

    await native.applyFileModes(<FileModeEntry>[
      FileModeEntry(paths.rootfsDir.path, 0x1ED),
      FileModeEntry(paths.homeDir.path, 0x1ED),
    ]);
  }

  Future<String> _detectFlavor(String rootfs) async {
    final File osRelease = File('$rootfs/etc/os-release');
    if (await osRelease.exists()) {
      try {
        String? pretty;
        String? name;
        for (final String line in await osRelease.readAsLines()) {
          final int equals = line.indexOf('=');
          if (equals <= 0) {
            continue;
          }
          final String key = line.substring(0, equals).trim();
          final String value =
              line.substring(equals + 1).trim().replaceAll('"', '');
          if (key == 'PRETTY_NAME') {
            pretty = value;
          } else if (key == 'NAME') {
            name = value;
          }
        }
        final String? detected = pretty ?? name;
        if (detected != null && detected.isNotEmpty) {
          return detected;
        }
      } catch (error) {
        AppLogger.instance.log('could not parse os-release: $error');
      }
    }
    return 'Linux';
  }

  static String _mb(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final double kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(0)} KiB';
    }
    return '${(kb / 1024).toStringAsFixed(1)} MiB';
  }
}

enum _ArchiveFormat { gzip, xz }

class _ArchiveAsset {
  const _ArchiveAsset(
      {required this.key, required this.bytes, required this.format});

  final String key;
  final Uint8List bytes;
  final _ArchiveFormat format;
}
