# Architecture

## 1. Layers

```
┌──────────────────────────────────────────────────────────────────┐
│ UI            bootstrap_screen · terminal_screen · diagnostics    │
├──────────────────────────────────────────────────────────────────┤
│ Session       terminal_session   (xterm Terminal ⇄ PTY)           │
├──────────────────────────────────────────────────────────────────┤
│ Linux         linux_environment · proot_command · rootfs_installer│
│               tar_extractor · install_progress (models)           │
├──────────────────────────────────────────────────────────────────┤
│ Bridge        pty_bridge (MethodChannel + EventChannel)           │
│               native_bridge (device info, chmod, exec checks)     │
├──────────────────────────────────────────────────────────────────┤
│ Android       MainActivity · PtyManager · NativeSupport · PtyNative│
│               pty_spawn.c (JNI, posix_openpt/fork/execve)         │
├──────────────────────────────────────────────────────────────────┤
│ Kernel        proot (ptrace) · proot loader · guest userland      │
└──────────────────────────────────────────────────────────────────┘
```

Nothing below the "Bridge" line knows about Flutter; nothing above it knows
about file descriptors. That split is what makes the sandbox testable and the
UI replaceable.

## 2. Storage layout

`getApplicationDocumentsDirectory()` on Android is
`/data/user/0/dev.prootbox.app/app_flutter`. All paths are defined in
`lib/src/core/app_paths.dart`.

| Host path | Guest path | Purpose |
| --- | --- | --- |
| `rootfs/` | `/` | extracted Linux userland |
| `rootfs/.prootbox-installed` | – | install marker + manifest (written last) |
| `home/` | `/root` | persistent home, survives reinstall |
| `resolv.conf` | `/etc/resolv.conf` | DNS (Android has none) |
| `cache/proot-tmp/` | – | `PROOT_TMP_DIR` |
| `cache/rootfs.arch`, `cache/rootfs.tar` | – | transient, deleted after install |
| `logs/prootbox.log` | – | diagnostics log |
| `settings.json` | – | shell, font size, proot flags |
| `environment.json` | – | flavour, default shell, archive, file count |

## 3. First-launch installation

`RootfsInstaller.install()` is deliberately crash-safe: the marker file is the
last thing written, so an interrupted run is simply retried.

```
preparing      delete partial rootfs, create layout
readingArchive rootBundle.load(assets/rootfs/rootfs.tar.gz)
               → chunked write to cache/rootfs.arch        (progress by bytes)
decompressing  gzip.decoder.bind(openRead()) → cache/rootfs.tar
                                                          (progress by input bytes)
extracting     TarExtractor → rootfs/*
               · ustar + GNU longname (L/K) + pax (x/g) headers
               · directories, regular files, symlinks, hardlinks
               · path sanitation (no absolute paths, no "..")
               · collects (path, mode) pairs
permissions    NativeBridge.applyFileModes → Kotlin Os.chmod, 400 per call
finalizing     /root fallback dir, resolv.conf, manifest, marker
```

Why a hand-written tar reader: the container is only correct if symlinks,
hardlinks and **mode bits** survive. `tar_extractor.dart` therefore keeps the
raw `mode`/`typeflag`/`linkname` fields and replays them, instead of handing the
archive to a generic extractor. Dart itself has no `chmod`, so the mode table is
applied through `android.system.Os.chmod` in `NativeSupport.kt`.

Format choice: `.tar.gz`, because `dart:io` has a native gzip decoder and
Android offers no `xz` decoder to an app. `--flavor ubuntu` and
`--flavor alpine` both publish `.tar.gz`, so nothing is lost.

## 4. Spawning PRoot

`ProotCommandBuilder.build()` produces the argv and environment. Defaults:

```
proot   -0 -L --kill-on-exit
        -S  <app>/app_flutter/rootfs
        -b  /dev -b /proc -b /sys
        -b  <app>/app_flutter/home:/root
        -b  <app>/app_flutter/resolv.conf:/etc/resolv.conf
        -w  /root
        /bin/sh -l
```

| Flag / variable | Reason |
| --- | --- |
| `-S` | stealth rootfs: recommended binds + fake `/etc/passwd` entries |
| `-0` | pretend uid/gid 0 so `apk`, `dpkg`, `npm -g` can write |
| `-L` | hard links become symlinks; required by npm-style installers |
| `--kill-on-exit` | no orphaned guest processes after the UI dies |
| `PROOT_TMP_DIR` | `/tmp` does not exist for an Android app |
| `PROOT_NO_SECCOMP=1` | Android's seccomp filter breaks PRoot's accelerator |
| `PROOT_LOADER` | the loader in `nativeLibraryDir` (see §6) |
| `TERM=xterm-256color` | 256-colour ANSI for the emulator |
| `LANG/LC_ALL=C.UTF-8` | predictable locale inside the guest |

The host process is started with `workingDirectory = app_flutter`, *outside* the
rootfs, so PRoot never has to resolve its own cwd through its own translation.

## 5. PTY session lifecycle

```
Dart                                    Kotlin                        C
────                                    ──────                        ─
PtyBridge.spawn(executable, argv, env)
  └─ invokeMethod("open")  ───────────▶ PtyManager.open
                                          └─ nativeSpawnPty ───────▶ posix_openpt
                                                                     grantpt/unlockpt
                                                                     fork
                                        ◀── [fd, pid]                setsid+TIOCSCTTY
  ◀── [sessionId, pid]                                               dup2(slave, 0/1/2)
  listener on EventChannel                reader thread:            execve(proot)
  session.output ─▶ utf8.decoder          nativeRead(fd) ─▶ events
       └─▶ terminal.write
  terminal.onOutput ─▶ invokeMethod("write") ─▶ writer executor ─▶ nativeWrite
  terminal.onResize ─▶ invokeMethod("resize") ─▶ nativeResize (TIOCSWINSZ ⇒ SIGWINCH)
  close ─────────────▶ SIGHUP to -pid ──▶ read() returns EIO ⇒ waitpid ⇒ exit event
```

* The session key is a monotonically increasing id owned by Kotlin, so
  reconnects never alias an old fd.
* Kernel EOF is `EIO` for a pty master; C maps it to `0` so the reader loop
  ends cleanly.
* The child resets all signal dispositions and the signal mask before `execve`,
  because the JVM installs handlers (and ignores `SIGPIPE`) in every thread.
* `fork()` is only safe because the child touches nothing but async-signal-safe
  calls. Every string it needs is `strdup`ed **before** the fork — JNI string
  pointers may be released by the parent while the child is between `fork` and
  `execve`.

## 6. Why `jniLibs` and `PROOT_LOADER`

Android 10 (API 29) added the W^X rule: an app may not `execve()` a file that
lives in app-writable storage (`app_data_file`). `chmod 0755` succeeds and the
`execve` still returns `EACCES`.

Two consequences:

1. **PRoot itself** must be executed from `ApplicationInfo.nativeLibraryDir`
   (`apk_data_file`, still executable). The installer only populates that
   directory from `lib/**/*.so` entries in the APK, which is why a real
   executable is shipped as `libproot.so`, and why `useLegacyPackaging = true`
   is set in `android/app/build.gradle`.
2. **Guest binaries** (`/bin/sh`, `/bin/bash`, …) are in app storage too. PRoot
   handles them itself: when `PROOT_LOADER` is set, PRoot executes that stub
   (from `nativeLibraryDir`) and the stub maps the guest ELF with
   `openat`+`mmap(PROT_EXEC)` — the `dlopen`-class permission apps keep — then
   jumps to its entry point. No kernel `execve` of guest storage ever happens.

If the loader is missing, the failure mode is misleading: PRoot starts, the PTY
opens, and every command returns `EACCES`. That is exactly why
`EnvironmentStatus` reports the loader separately and the Diagnostics sheet
shows it.

## 7. Error modelling

* `EnvironmentException` — blocking sandbox problem with a human `hint`
  (missing asset, non-executable binary, corrupt archive).
* `PtyException` — spawn/write failure, carrying `errno` when the kernel
  provided one; `describeErrno` turns it into text (`EACCES` ⇒ SELinux hint).
* `AppLogger` — ring buffer + `logs/prootbox.log`, surfaced in Diagnostics and
  copyable as a bug report.

## 8. Deliberate non-goals

* Multiple simultaneous sessions in the UI (the bridge supports N sessions; the
  screen runs one).
* External storage bind (`/sdcard`): needs `MANAGE_EXTERNAL_STORAGE` and breaks
  Play policy; add `-b /storage/emulated/0:/sdcard` to `extraBinds` if you
  accept that.
* Distribution of prebuilt binaries through git.
