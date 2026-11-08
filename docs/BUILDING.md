# Building

This project is source-complete but intentionally ships **no binaries**. Two
generated artefacts are required at runtime, and one generated file
(`gradle-wrapper.jar`) is required to build.

```
scripts/prepare-assets.sh      # rootfs.tar.gz + libproot.so + libproot-loader.so
scripts/bootstrap.sh           # gradle wrapper + flutter pub get
flutter run                    # (an APK build is out of scope for this project)
```

## 1. Toolchain

| Tool | Version | Notes |
| --- | --- | --- |
| Flutter | 3.47.x (verified: 3.47.9, Dart 3.13.7) | `sdk: '>=3.6.0 <4.0.0'` |
| Java | 17 | AGP 9 / Gradle 9 minimum |
| Gradle | 9.3.1 | `android/gradle/wrapper/gradle-wrapper.properties` |
| AGP | 9.1.0 | the version Flutter 3.47 is verified against |
| Kotlin (KGP) | 2.4.0 | with `android.builtInKotlin=false`, as in the Flutter template |
| Android SDK | `compileSdk` from Flutter (36), build-tools 36 | `targetSdk 34`, `minSdk 26` |
| Android NDK | r21+ (r26–r29 tested upstream) | needed for `proot` **and** for the JNI PTY lib |
| CMake | 3.22.1 | declared in `android/app/build.gradle.kts` |
| git, curl, make | – | asset scripts |

Set `ANDROID_NDK_HOME` if the NDK is not in a default SDK location.

## 2. The Linux root filesystem

```bash
./scripts/build-rootfs.sh                  # Alpine latest-stable aarch64 (~3 MB)
./scripts/build-rootfs.sh --flavor ubuntu  # Ubuntu Base 24.04 arm64 (~30 MB)
./scripts/build-rootfs.sh --url https://…/custom.tar.gz --flavor custom
```

Output: `assets/rootfs/rootfs.tar.gz` plus `assets/rootfs/rootfs.json`
(source URL, sha256, size, date). The script verifies the upstream checksum
when the mirror publishes one.

Notes:

* **gzip only.** The runtime decompresses with `dart:io`; Android exposes no
  `xz` decoder to apps, so `.tar.xz` would have to be unpacked by a native
  library. If you must ship xz, convert it: `xz -dc in.tar.xz | gzip > rootfs.tar.gz`.
* Alpine is the default because it is small and `apk` is fast. It has **no
  bash** (`/bin/sh` is busybox ash); run `apk add bash` in the terminal (needs
  network) or choose the Ubuntu flavour.
* To bake tools into the image, unpack it on a Linux host, chroot (or
  `proot -S`), install, re-pack with `tar --numeric-owner -czf`.

## 3. PRoot + its loader

```bash
./scripts/build-proot.sh
# or: ANDROID_NDK_HOME=~/Android/Sdk/ndk/27.0.12077973 ./scripts/build-proot.sh
```

What it does:

1. downloads `talloc 2.4.2` and compiles it as a single unit against bionic
   (a minimal `replace.h` stands in for Samba's waf build),
2. clones `termux/proot` (`PROOT_REPO`, `PROOT_REF` overridable — Termux's fork
   carries the Android patches and builds the loader),
3. builds with NDK clang for `aarch64-linux-android26`,
4. strips and installs:

```
android/app/src/main/jniLibs/arm64-v8a/libproot.so
android/app/src/main/jniLibs/arm64-v8a/libproot-loader.so
android/app/src/main/jniLibs/arm64-v8a/libproot-loader32.so   (if built)
```

Both filenames are load-bearing: the installer only extracts `lib/**/*.so` into
`ApplicationInfo.nativeLibraryDir`, the one place Android 10+ lets an app
execute from. **proot and loader must come from the same build** — mixing a
loader from a different proot revision can SIGSEGV the guest on some ROMs.

Build failures worth knowing:

| Error | Fix |
| --- | --- |
| `talloc.h: No such file` | delete `third_party/talloc/` and rerun (it re-fetches) |
| `undefined reference to __android_log_*` | NDK ≥ r23 drops implicit `-llog`; add `-llog` to `LDFLAGS` |
| `loader/loader` missing | the script retries the explicit target; check `PROOT_REF` supports it |
| guest SIGSEGV at first instruction | proot/loader from different builds, or a very old NDK; rebuild both |

If you prefer a prebuilt pair, drop them into the same two paths — they are
gitignored, so nothing else changes.

## 4. Flutter + Gradle

```bash
./scripts/bootstrap.sh
```

The Gradle wrapper (`gradlew`, `gradlew.bat`, `gradle-wrapper.jar`) is a binary
and follows Flutter's convention of not being committed (`android/.gitignore`).
`bootstrap.sh` regenerates it from a throw-away `flutter create` scaffold,
copying **only** those three files — it never runs `flutter create` over this
project, so the hand-written Android sources are never touched. It then runs
`flutter pub get`.

Build scripts are Kotlin DSL (`*.gradle.kts`) because Gradle 9 removed
`Project.buildDir`. Two Flutter-template flags in `android/gradle.properties`
keep AGP 9 in the mode Flutter supports:

```properties
android.newDsl=false
android.builtInKotlin=false
```

The mandatory native-library setting lives in `android/app/build.gradle.kts`:

```kotlin
packaging {
    jniLibs {
        useLegacyPackaging = true   // extract libproot*.so to nativeLibraryDir
    }
}
```

`android/local.properties` (`sdk.dir`, `flutter.sdk`) is machine-specific and
gitignored; the Flutter tool writes it, or copy `android/local.properties.example`.

## 5. Verification

```bash
flutter analyze                       # static analysis
flutter run -d <device>               # first launch shows extraction progress
```

On the device, open menu → **Diagnostics**. A healthy sandbox reports:

| Entry | Expected |
| --- | --- |
| PRoot binary | `/data/app/…/lib/arm64/libproot.so`, ok |
| PRoot source | `nativeLibraryDir` |
| PROOT_LOADER | `/data/app/…/lib/arm64/libproot-loader.so`, ok |
| Root filesystem | `Alpine Linux (installed)` / `Ubuntu (installed)` |
| `/bin/sh` | present |

Then in the shell:

```sh
uname -a                 # Linux … aarch64
id                       # uid=0(root) (faked by proot -0)
cat /etc/os-release
apk add --no-cache curl  # or: apt-get update && apt-get install -y curl
echo $TERM               # xterm-256color
```

UI checks: `Ctrl-C` interrupts, `↑` recalls history, `vim`/`htop` fill the
screen, rotating the device or opening the keyboard re-flows a TUI.

## 6. targetSdk and distribution

`targetSdk 34` works because of the `PROOT_LOADER` mechanism; there is no need
to lower it to 28 (the old Termux trick, which disables the W^X rule but is
rejected by Play). Two consequences to keep in mind:

* **Do not remove `useLegacyPackaging = true`.** Without extracted native
  libs, `libproot.so` and the loader stay inside the APK and cannot be executed.
  (AGP 9 also removed the `android:extractNativeLibs` manifest attribute — the
  Gradle DSL is now the only place this can be set.)
* `minSdk 26` because `android.system.Os`/`posix_openpt` and per-app SELinux
  domains are only predictable from API 26 onward.

Google Play policy treats an app that downloads/executes arbitrary code
conservatively. Distribute through GitHub releases / F-Droid, or review the
policy before publishing to Play.

## 7. Releasing

```bash
flutter build appbundle --release       # or: flutter build apk --release
```

`release` currently signs with the debug key so it installs without setup —
create a keystore and a `key.properties` before a real release. The APK contains
the rootfs asset, so it grows by the size of `rootfs.tar.gz` (Alpine ≈ 3 MB,
Ubuntu ≈ 30 MB, plus the extracted container at runtime).

## 8. Updating components

| Component | How |
| --- | --- |
| rootfs | rerun `build-rootfs.sh`; users must *Reinstall environment* (or clear app data) |
| proot / loader | rerun `build-proot.sh`; a normal app update replaces them |
| shells/settings | in-app menu, persisted to `settings.json` |
| assets dir names | keep `assets/rootfs/rootfs.tar.gz`; the runtime also probes `.tar.xz` and fails with a clear hint |
