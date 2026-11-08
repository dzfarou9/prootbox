/// Fatal problem with the sandbox (missing binary, corrupt rootfs, ...).
class EnvironmentException implements Exception {
  const EnvironmentException(this.message, {this.hint});

  final String message;

  /// Actionable next step shown in the UI.
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message\n$hint';
}

enum InstallPhase {
  preparing,
  readingArchive,
  decompressing,
  extracting,
  permissions,
  finalizing,
  ready,
}

extension InstallPhaseLabel on InstallPhase {
  String get label {
    switch (this) {
      case InstallPhase.preparing:
        return 'Preparing private storage';
      case InstallPhase.readingArchive:
        return 'Staging root filesystem';
      case InstallPhase.decompressing:
        return 'Decompressing archive';
      case InstallPhase.extracting:
        return 'Extracting Linux userland';
      case InstallPhase.permissions:
        return 'Applying POSIX permissions';
      case InstallPhase.finalizing:
        return 'Finalising sandbox';
      case InstallPhase.ready:
        return 'Ready';
    }
  }
}

class InstallProgress {
  const InstallProgress(this.phase, this.fraction, this.message);

  final InstallPhase phase;
  final double fraction;
  final String message;

  @override
  String toString() =>
      '${phase.name} ${(fraction * 100).toStringAsFixed(0)}% $message';
}

typedef InstallProgressCallback = void Function(InstallProgress progress);

/// Everything we remember about the installed container.
class EnvironmentManifest {
  const EnvironmentManifest({
    required this.flavor,
    required this.shell,
    required this.archive,
    required this.installedAt,
    required this.files,
  });

  final String flavor;
  final String shell;
  final String archive;
  final String installedAt;
  final int files;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'flavor': flavor,
        'shell': shell,
        'archive': archive,
        'installedAt': installedAt,
        'files': files,
      };

  factory EnvironmentManifest.fromJson(Map<String, dynamic> json) {
    return EnvironmentManifest(
      flavor: json['flavor'] as String? ?? 'Linux',
      shell: json['shell'] as String? ?? '/bin/sh',
      archive: json['archive'] as String? ?? 'rootfs.tar.gz',
      installedAt: json['installedAt'] as String? ?? '',
      files: (json['files'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Where the PRoot executable + its syscall loader were found.
class ProotBinaries {
  const ProotBinaries({
    required this.prootPath,
    required this.loaderPath,
    required this.source,
    required this.prootExecutable,
    required this.loaderExecutable,
  });

  /// Absolute path of the `proot` ELF, or null when nothing was found.
  final String? prootPath;

  /// Absolute path of PRoot's per-tracee loader (`PROOT_LOADER`).
  final String? loaderPath;

  /// `nativeLibraryDir`, `assets` or `missing`.
  final String source;

  final bool prootExecutable;
  final bool loaderExecutable;

  bool get isUsable => prootPath != null && prootExecutable;

  bool get hasLoader => loaderPath != null && loaderExecutable;

  static const ProotBinaries missing = ProotBinaries(
    prootPath: null,
    loaderPath: null,
    source: 'missing',
    prootExecutable: false,
    loaderExecutable: false,
  );
}

class DiagnosticEntry {
  const DiagnosticEntry(this.label, this.value,
      {this.ok = true, this.fatal = false});

  final String label;
  final String value;
  final bool ok;

  /// Marks the checks that make the sandbox unusable when they fail.
  final bool fatal;
}

class EnvironmentStatus {
  const EnvironmentStatus({
    required this.rootfsInstalled,
    required this.binaries,
    required this.diagnostics,
    required this.manifest,
  });

  final bool rootfsInstalled;
  final ProotBinaries binaries;
  final List<DiagnosticEntry> diagnostics;
  final EnvironmentManifest? manifest;

  bool get isReady => rootfsInstalled && binaries.isUsable;

  /// Blocks a *usable* terminal: no rootfs or no executable proot.
  bool get hasBlockingProblem => !rootfsInstalled || !binaries.isUsable;

  /// Non-blocking but breaks `execve` of guest binaries on Android 10+.
  bool get loaderMissing => binaries.isUsable && !binaries.hasLoader;

  String describeBlockingProblem() {
    if (!binaries.isUsable) {
      if (binaries.prootPath == null) {
        return 'The PRoot binary is missing from this build.';
      }
      return 'The PRoot binary exists but cannot be executed on this device.';
    }
    if (!rootfsInstalled) {
      return 'The Linux root filesystem has not been installed yet.';
    }
    return 'The sandbox is not ready.';
  }

  String describeHint(int sdkInt) {
    if (binaries.prootPath == null) {
      return 'Run scripts/build-proot.sh, then rebuild the app (see docs/BUILDING.md).';
    }
    if (!binaries.prootExecutable && sdkInt >= 29) {
      return 'Android 10+ only allows executing files from the app native library '
          'directory. Make sure jniLibs/arm64-v8a/libproot.so is packaged with '
          'android:extractNativeLibs="true".';
    }
    if (loaderMissing) {
      return 'PROOT_LOADER (libproot-loader.so) is missing, so guest binaries '
          '(/bin/sh, /bin/bash) cannot be executed on Android 10+.';
    }
    return 'Open Diagnostics for the full report.';
  }
}
