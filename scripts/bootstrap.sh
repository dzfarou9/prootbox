#!/usr/bin/env bash
#
# bootstrap.sh — prepare a fresh checkout for development.
#
#   1. verify the Flutter toolchain
#   2. restore the Gradle wrapper JAR (a binary, so it is not in git) by
#      generating a throw-away scaffold and copying only the wrapper files.
#      This deliberately never runs `flutter create` over this project, so the
#      hand-written Android sources are never touched.
#   3. flutter pub get
#   4. warn about missing runtime artefacts
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"

info() { printf '\033[0;36m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH (https://docs.flutter.dev/get-started/install)"
command -v dart >/dev/null 2>&1 || die "dart is not on PATH"

info "$(flutter --version | head -n 1)"

if [[ ! -f "$ANDROID_DIR/gradle/wrapper/gradle-wrapper.jar" ]]; then
    info "restoring Gradle wrapper (gradle-wrapper.jar is not tracked in git)"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    (
        cd "$TMP_DIR"
        flutter create --platforms=android --project-name prootbox \
            --org dev.prootbox scaffold >/dev/null
    )
    mkdir -p "$ANDROID_DIR/gradle/wrapper"
    cp "$TMP_DIR/scaffold/android/gradle/wrapper/gradle-wrapper.jar" \
        "$ANDROID_DIR/gradle/wrapper/gradle-wrapper.jar"
    cp "$TMP_DIR/scaffold/android/gradlew" "$ANDROID_DIR/gradlew"
    cp "$TMP_DIR/scaffold/android/gradlew.bat" "$ANDROID_DIR/gradlew.bat"
    chmod +x "$ANDROID_DIR/gradlew"
    info "Gradle wrapper restored"
else
    info "Gradle wrapper already present"
fi

info "flutter pub get"
(cd "$ROOT_DIR" && flutter pub get)

MISSING=0
if ! compgen -G "$ROOT_DIR/assets/rootfs/rootfs.tar.gz" >/dev/null; then
    warn "assets/rootfs/rootfs.tar.gz is missing → run scripts/build-rootfs.sh"
    MISSING=1
fi
if ! compgen -G "$ANDROID_DIR/app/src/main/jniLibs/arm64-v8a/libproot.so" >/dev/null; then
    warn "jniLibs/arm64-v8a/libproot.so is missing → run scripts/build-proot.sh (needs the Android NDK)"
    MISSING=1
fi

if [[ "$MISSING" == "1" ]]; then
    cat <<'EOF'

The Dart/Android sources are complete; only the binary payload is missing.
Run:

    scripts/prepare-assets.sh

EOF
else
    info "all runtime artefacts present — ready for: flutter run"
fi
