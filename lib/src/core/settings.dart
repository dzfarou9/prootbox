import 'dart:convert';
import 'dart:io';

import 'logger.dart';

/// User-visible runtime preferences, persisted as JSON next to the rootfs.
class AppSettings {
  AppSettings({
    this.shellPath,
    this.fontSize = 13,
    this.fakeRoot = true,
    this.link2Symlink = true,
    this.killOnExit = true,
    this.disableSeccomp = true,
  });

  /// Explicit guest login shell, e.g. `/bin/bash`.
  ///
  /// `null` means "auto-detect": use whatever the installed rootfs reports
  /// (`/bin/bash` on Ubuntu, `/bin/sh` on Alpine). Keeping `null` as the
  /// default is what lets the flavour decide instead of hard-coding posix sh.
  String? shellPath;

  double fontSize;

  /// `proot -0`: pretend to be uid/gid 0 (makes `apk`, `dpkg`, `npm -g` work).
  bool fakeRoot;

  /// `proot -L`: emulate hard links with symlinks. Required by npm-style
  /// installers that try to hard-link across the sandbox boundary.
  bool link2Symlink;

  /// `proot --kill-on-exit`: kill guest processes when the session ends.
  bool killOnExit;

  /// `PROOT_NO_SECCOMP=1`: Android's seccomp filter breaks PRoot's seccomp
  /// acceleration on several devices; disabling it is the safe default.
  bool disableSeccomp;

  AppSettings copyWith({
    String? shellPath,
    double? fontSize,
    bool? fakeRoot,
    bool? link2Symlink,
    bool? killOnExit,
    bool? disableSeccomp,
  }) {
    return AppSettings(
      shellPath: shellPath ?? this.shellPath,
      fontSize: fontSize ?? this.fontSize,
      fakeRoot: fakeRoot ?? this.fakeRoot,
      link2Symlink: link2Symlink ?? this.link2Symlink,
      killOnExit: killOnExit ?? this.killOnExit,
      disableSeccomp: disableSeccomp ?? this.disableSeccomp,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'shellPath': shellPath,
        'fontSize': fontSize,
        'fakeRoot': fakeRoot,
        'link2Symlink': link2Symlink,
        'killOnExit': killOnExit,
        'disableSeccomp': disableSeccomp,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final Object? fontSize = json['fontSize'];
    return AppSettings(
      shellPath:
          json['shellPath'] is String ? json['shellPath'] as String : null,
      fontSize: fontSize is num ? fontSize.toDouble() : 13,
      fakeRoot: json['fakeRoot'] is bool ? json['fakeRoot'] as bool : true,
      link2Symlink:
          json['link2Symlink'] is bool ? json['link2Symlink'] as bool : true,
      killOnExit:
          json['killOnExit'] is bool ? json['killOnExit'] as bool : true,
      disableSeccomp: json['disableSeccomp'] is bool
          ? json['disableSeccomp'] as bool
          : true,
    );
  }
}

class SettingsStore {
  SettingsStore(this.file);

  final File file;

  Future<AppSettings> load() async {
    try {
      if (!await file.exists()) {
        return AppSettings();
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return AppSettings.fromJson(decoded);
      }
    } catch (error, stackTrace) {
      AppLogger.instance.logError('failed to read settings', error, stackTrace);
    }
    return AppSettings();
  }

  Future<void> save(AppSettings settings) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      );
    } catch (error, stackTrace) {
      AppLogger.instance
          .logError('failed to write settings', error, stackTrace);
    }
  }
}
