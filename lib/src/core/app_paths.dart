import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// All filesystem locations used by the sandbox.
///
/// Everything lives under `getApplicationDocumentsDirectory()` — i.e.
/// `/data/user/0/<package>/app_flutter` — so the app never needs external
/// storage permissions, scoped-storage exemptions or `MANAGE_EXTERNAL_STORAGE`.
///
/// Layout (after installation):
///
///     app_flutter/
///       rootfs/                 <- Alpine/Ubuntu ARM64 userland (the container)
///         bin/sh, usr/, etc/...
///         .prootbox-installed   <- idempotency marker + manifest
///       home/                   <- bind-mounted onto /root inside the guest
///       cache/
///         proot-tmp/            <- PRoot's PROOT_TMP_DIR
///         rootfs.tar            <- transient, deleted after extraction
///       logs/prootbox.log
///       resolv.conf             <- bind-mounted onto /etc/resolv.conf
///       settings.json
///       environment.json
class AppPaths {
  AppPaths(this.rootDir);

  /// Root of all app-owned data.
  final Directory rootDir;

  static Future<AppPaths> resolve() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    return AppPaths(documents);
  }

  String get root => rootDir.path;

  /// The container root filesystem.
  Directory get rootfsDir => Directory('$root/rootfs');

  /// Persistent `$HOME` of the guest, bind-mounted to `/root`.
  Directory get homeDir => Directory('$root/home');

  Directory get cacheDir => Directory('$root/cache');

  /// PRoot's scratch directory (`PROOT_TMP_DIR`). Must be app-writable:
  /// the guest-visible `/tmp` does not exist on the host.
  Directory get prootTmpDir => Directory('$root/cache/proot-tmp');

  Directory get logDir => Directory('$root/logs');

  File get logFile => File('$root/logs/prootbox.log');

  /// DNS configuration handed to the guest (Android has no /etc/resolv.conf).
  File get resolvConf => File('$root/resolv.conf');

  /// Describes the installed rootfs (flavour, default shell, install date).
  File get environmentManifest => File('$root/environment.json');

  /// User-tweakable runtime preferences.
  File get settingsFile => File('$root/settings.json');

  /// Marker written last; its presence means "rootfs is complete".
  File get installMarker => File('${rootfsDir.path}/.prootbox-installed');

  /// Transient staging area for the rootfs archive.
  File get stagedArchive => File('$root/cache/rootfs.arch');
  File get stagedTar => File('$root/cache/rootfs.tar');

  /// Fallback location for a proot binary extracted from assets.
  /// Only executable on legacy `targetSdk <= 28` builds (Android 10+ W^X).
  Directory get binDir => Directory('$root/bin');

  /// Creates every directory the runtime expects. Safe to call repeatedly.
  Future<void> ensureLayout() async {
    for (final Directory dir in <Directory>[
      rootDir,
      rootfsDir,
      homeDir,
      cacheDir,
      prootTmpDir,
      logDir,
      binDir,
    ]) {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
  }

  Future<void> deleteRecursively(FileSystemEntity entity) async {
    if (await entity.exists()) {
      await entity.delete(recursive: true);
    }
  }
}
