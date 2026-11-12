# ProotBox

A **self-contained PRoot Linux sandbox for Android**, written from scratch with
Flutter. The app ships its own PRoot binaries and its own ARM64 Linux userland,
unpacks them into its private storage on first launch, and gives you a real
interactive terminal — no Termux, no PRoot-Distro, no root, no companion app.

```
┌──────────────────────────── ProotBox (single APK) ────────────────────────────┐
│                                                                              │
│  Flutter UI (xterm.dart)                                                     │
│      │  UTF-8 in/out                                   ┌───────────────────┐  │
│      ▼                                                 │  libproot.so      │  │
│  PtyBridge ──MethodChannel──▶ PtyManager (Kotlin) ───▶ │  libproot-loader  │  │
│      ▲                            │  reader/writer     └───────────────────┘  │
│      │                            ▼                        (nativeLibraryDir) │
│  EventChannel ◀──────────── pty master ◀── fork/exec ◀── proot                │
│                                                            │                  │
│                                                            ▼                  │
│                                       /data/user/0/dev.prootbox.app/          │
│                                         app_flutter/rootfs  (Alpine/Ubuntu)   │
│                                         app_flutter/home    → guest /root     │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Status of the five phases

| Phase | Deliverable | Where |
| --- | --- | --- |
| 1 | Project architecture, asset layout, dependencies | [`pubspec.yaml`](pubspec.yaml), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| 2 | Asset extraction + `chmod 0755` + progress UI | [`lib/src/linux/rootfs_installer.dart`](lib/src/linux/rootfs_installer.dart), [`lib/src/linux/tar_extractor.dart`](lib/src/linux/tar_extractor.dart), [`lib/src/ui/bootstrap_screen.dart`](lib/src/ui/bootstrap_screen.dart) |
| 3 | PRoot spawn + bindings + environment | [`lib/src/linux/proot_command.dart`](lib/src/linux/proot_command.dart), [`lib/src/linux/linux_environment.dart`](lib/src/linux/linux_environment.dart), [`android/app/src/main/cpp/pty_spawn.c`](android/app/src/main/cpp/pty_spawn.c) |
| 4 | Interactive terminal (stdin/stdout/stderr, ANSI, PTY size, keys) | [`lib/src/terminal/terminal_session.dart`](lib/src/terminal/terminal_session.dart), [`lib/src/ui/terminal_screen.dart`](lib/src/ui/terminal_screen.dart), [`lib/src/ui/widgets/terminal_key_bar.dart`](lib/src/ui/widgets/terminal_key_bar.dart) |
| 5 | GitHub publication | [`scripts/publish-github.sh`](scripts/publish-github.sh), [below](#publishing-to-github) |

## Requirements

* Flutter 3.19+ (Dart 3.4+), Android SDK 34, Android NDK (r21+), CMake 3.22
* Target device: **Android 9+ (API 26), arm64-v8a**
* ~120 MB free storage for the Alpine container (Ubuntu: ~400 MB)

## Quick start

```bash
git clone <this repo> prootbox && cd prootbox

# 1. binary payload (gitignored build artefacts)
./scripts/prepare-assets.sh          # Alpine rootfs + proot + loader
#    ./scripts/prepare-assets.sh --flavor ubuntu

# 2. dependencies + Gradle wrapper (a binary, so it is not in git)
./scripts/bootstrap.sh

# 3. run (NOT part of the requested scope: no APK was built in this project)
flutter run
```

Toolchain this tree is written against: **Flutter 3.47.9 / Dart 3.13.7**, Android
Gradle Plugin 9.1.0, Gradle 9.3.1, Kotlin Gradle Plugin 2.4.0, Java 17
(`compileSdk` from the Flutter SDK, `minSdk 26`, `targetSdk 34`). Dart analysis
passes with zero issues on that toolchain; see [Verification](#verification).

`scripts/prepare-assets.sh` produces:

```
assets/rootfs/rootfs.tar.gz                                  Alpine minirootfs (aarch64)
android/app/src/main/jniLibs/arm64-v8a/libproot.so           PRoot, cross-compiled with the NDK
android/app/src/main/jniLibs/arm64-v8a/libproot-loader.so    PRoot's per-tracee syscall loader
```

On first launch the app shows an extraction screen, unpacks the userland,
applies the POSIX modes recorded in the tar, and drops you into the shell.

## Using the terminal

* **Login shell** — `/bin/sh` on Alpine (busybox ash), `/bin/bash` on Ubuntu.
  Menu → *Login shell…* switches shells.
* **Extra keys bar** — `ESC`, `TAB`, `^C`, `^D`, `^Z`, `^L`, `^R`, arrows,
  `HOME`/`END`, `|`, `~`, `/`, `-`.
* **Paste** — toolbar button or long-press on the terminal.
* **Window size** — the PTY is resized whenever the view or keyboard changes, so
  the guest gets a real `SIGWINCH` and TUIs re-layout.
* **Home directory** — `app_flutter/home` is bind-mounted to `/root`, so shell
  history, `~/.config` and installed tools survive *Reinstall environment*.
* **Reinstall** — Menu → *Reinstall environment* wipes only the container.

### Example: OpenCode AI inside the sandbox

```sh
apk update && apk add nodejs npm git curl   # (Ubuntu: apt-get install nodejs npm git curl)
npm install -g opencode-ai
opencode
```

Networking works because the guest shares the Android app's network namespace;
DNS comes from `app_flutter/resolv.conf`, which is bind-mounted onto
`/etc/resolv.conf` (Android itself has no such file).

## Repository layout

```
lib/
  main.dart                              app entry
  src/app_services.dart                  dependency container (paths, bridge, env)
  src/core/                              app paths, settings, diagnostics log
  src/native/native_bridge.dart          device info, chmod batches, exec checks
  src/native/pty_bridge.dart             MethodChannel/EventChannel PTY client
  src/linux/linux_environment.dart       binary discovery, status, launch specs
  src/linux/rootfs_installer.dart        first-launch extraction pipeline
  src/linux/tar_extractor.dart           hand-written ustar/pax reader (modes!)
  src/linux/proot_command.dart           the PRoot argv + environment
  src/terminal/terminal_session.dart     xterm ⇄ PTY wiring
  src/ui/                                bootstrap, terminal, diagnostics, theme
android/app/src/main/
  kotlin/dev/prootbox/app/MainActivity.kt      channel registration
  kotlin/dev/prootbox/app/PtyManager.kt        sessions, reader/writer threads
  kotlin/dev/prootbox/app/PtyNative.kt         JNI declarations
  kotlin/dev/prootbox/app/NativeSupport.kt     device info, Os.chmod
  cpp/pty_spawn.c                              posix_openpt + fork + execve
  jniLibs/arm64-v8a/                           libproot.so, libproot-loader.so
assets/rootfs/                                 rootfs.tar.gz (generated)
scripts/                                       asset + publish tooling
docs/                                          architecture and build notes
```

## The three Android constraints that shape this design

1. **Android 10+ forbids `execve()` of files in app storage** (SELinux W^X,
   `untrusted_app` has no `execute_no_trans` on `app_data_file`). PRoot itself
   *and* its loader therefore ship as `jniLibs/*.so` and are executed from
   `ApplicationInfo.nativeLibraryDir`. This requires
   `useLegacyPackaging = true` so the installer actually extracts them.
2. **Guest binaries cannot be `execve`d either.** PRoot solves this with its
   loader: the app sets `PROOT_LOADER=<nativeLibraryDir>/libproot-loader.so`,
   and PRoot maps each guest ELF through that stub instead of asking the kernel
   to execute it. Without this, PRoot starts, prints a prompt-less session and
   every command fails with `EACCES`. The app's Diagnostics sheet reports it.
3. **Dart pipes are not a terminal.** `Process.start()` cannot allocate a PTY,
   so a tiny JNI library does `posix_openpt` + `grantpt` + `unlockpt` +
   `fork`/`execve`, makes the slave the child's controlling terminal
   (`setsid`, `TIOCSCTTY`) and resets every signal handler the JVM installed.
   That is what makes job control, `Ctrl-C`, `SIGWINCH` and full-screen TUIs work.

A fourth, softer one: Android has no `/etc/resolv.conf` and no `/tmp` for apps,
hence the generated `resolv.conf` bind and `PROOT_TMP_DIR` under app storage.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| "No root filesystem is bundled with this build" | `assets/rootfs/rootfs.tar.gz` missing | `./scripts/build-rootfs.sh` |
| "The PRoot binary is missing from this build" | `jniLibs/…/libproot.so` missing | `./scripts/build-proot.sh` |
| "PRoot binary exists but cannot be executed" | native libs not extracted (modern packaging) | keep `useLegacyPackaging = true`, rebuild |
| `PROOT_LOADER` shows *missing* in Diagnostics | loader not built/packaged | `./scripts/build-proot.sh` (builds both) |
| `execve("/bin/sh"): Permission denied` | `PROOT_LOADER` not set/failed | Diagnostics → rebuild assets |
| `can't access tty; job control turned off` | PTY not the controlling terminal | ensure native lib `prootbox_pty` is built (CMake) |
| Guest has no DNS | blocked network / no resolv.conf bind | check `app_flutter/resolv.conf`, `apk add` again |
| `apk`/`npm -g` cannot write | `-0` (fake root) disabled | keep `fakeRoot` on in settings |

Diagnostics (toolbar → menu → *Diagnostics*) prints every path, both binary
locations, the loader state, the install manifest and the runtime log; *Copy
report* puts it on the clipboard.

## Publishing to GitHub

```bash
gh auth login                     # once
git config --global user.name  "You"
git config --global user.email "you@example.com"

./scripts/publish-github.sh                 # public repo named "prootbox"
./scripts/publish-github.sh --name proot-sandbox --private
```

The script initialises the repository (branch `main`), stages everything,
refuses to commit the generated binaries, commits, creates the GitHub repository
with `gh repo create --source=. --push` and prints the resulting URL. If `gh` is
unavailable it prints the exact manual `git remote add` / `git push` sequence.

## Continuous integration

A [GitHub Actions workflow](.github/workflows/build.yml) builds the Android APK
on every push to `main` and on pull requests. It targets the same toolchain this
tree is written against (Flutter 3.47.9, Java 17, AGP 9.1.0, Gradle 9.3.1,
KGP 2.4.0) and uploads the resulting `app-release.apk` as a workflow artefact.

Because the two runtime payloads (`assets/rootfs/rootfs.tar.gz` and the proot
binaries) are gitignored and are generated by `scripts/prepare-assets.sh`, a
fresh checkout's CI run packages a *non-runnable* APK and emits a warning plus a
step-summary note. Add the payloads (or commit them, if you intend a self-contained
distribution) and the same workflow will upload a runnable APK.

## Verification

What was actually checked while building this project (no APK was built):

| Check | Result |
| --- | --- |
| `flutter pub get` (Flutter 3.47.9, xterm 4.0.0) | resolves |
| `flutter analyze` | **No issues found** (0 errors, 0 warnings, 0 infos) |
| `bash -n` on all `scripts/*.sh` | clean |
| `gcc -fsyntax-only -Wall -Wextra` on `pty_spawn.c` against real `jni.h` | clean |
| Kotlin (`PtyManager`, `NativeSupport`, `PtyNative`, `MainActivity`) | **not compiled** — needs the Android SDK/NDK, unavailable in the authoring environment |
| Gradle/AGP configuration | **not executed** — same reason; versions mirror the Flutter 3.47 template (AGP 9.1.0 / Gradle 9.3.1 / KGP 2.4.0) |
| On-device run | **not performed** |

So: the Dart layer is compiler-verified, the JNI C file is compiler-verified,
and the Android/Kotlin/Gradle layer is written to the current platform APIs but
has not been through a Gradle build yet. The [CI workflow](.github/workflows/build.yml)
is the first attempt at a Gradle build; the [on-device checklist](docs/BUILDING.md#5-verification)
completes it once an Android SDK is available.

## Scope notes

* **No APK was built** for this project — only sources, configuration and
  tooling, as requested.
* The two binary artefacts (rootfs, proot) are generated by the scripts and
  intentionally **not** committed; a clone is only *runnable* after
  `scripts/prepare-assets.sh`.
* `arm64-v8a` only. Other ABIs need matching proot binaries in
  `scripts/build-proot.sh` plus an `abiFilters` change.
* Add your own `LICENSE` before publishing if you want one; none is implied.
