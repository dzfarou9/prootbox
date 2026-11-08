#!/usr/bin/env bash
#
# build-proot.sh — cross-compile PRoot (+ its syscall loader) for Android ARM64
# and install both into jniLibs, where the Android installer extracts them into
# ApplicationInfo.nativeLibraryDir.
#
# Why they must live in jniLibs:
#   Android 10+ forbids execve() of any file in app-writable storage
#   (untrusted_app has no execute_no_trans on app_data_file — the W^X rule).
#   The installed native-lib directory (apk_data_file) is the exception, and it
#   is populated *only* from lib/**/*.so entries inside the APK. Hence the
#   ".so" suffix on what are really two executables.
#
#   * libproot.so         the PRoot binary itself
#   * libproot-loader.so  PRoot's per-tracee loader. PRoot execve()s this
#                         instead of the guest ELF, so guest binaries are
#                         mapped (dlopen-class permission) rather than exec'd.
#                         The app passes it as PROOT_LOADER. Without it PRoot
#                         starts fine but every command dies with EACCES.
#
# Requirements: Android NDK r21+, git, curl, make, standard binutils.
#
# Usage:
#   scripts/build-proot.sh                     # NDK auto-detected
#   ANDROID_NDK_HOME=/path/to/ndk scripts/build-proot.sh
#   PROOT_REPO=... PROOT_REF=... scripts/build-proot.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JNI_DIR="$ROOT_DIR/android/app/src/main/jniLibs/arm64-v8a"
BUILD_DIR="$ROOT_DIR/scripts/.build/proot-aarch64"
PROOT_DIR="$ROOT_DIR/third_party/proot"
TALLOC_DIR="$ROOT_DIR/third_party/talloc"

ANDROID_API="${ANDROID_API:-26}"
TARGET_TRIPLE="aarch64-linux-android"
TALLOC_VERSION="${TALLOC_VERSION:-2.4.2}"
PROOT_REPO="${PROOT_REPO:-https://github.com/termux/proot}"
PROOT_REF="${PROOT_REF:-master}"

info() { printf '\033[0;36m[build-proot]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[build-proot]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[build-proot]\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v make >/dev/null 2>&1 || die "make is required"

# --------------------------------------------------------------- locate NDK
resolve_ndk() {
    local candidate
    for candidate in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"; do
        if [[ -n "$candidate" && -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    local base latest
    for base in \
        "${ANDROID_SDK_ROOT:-}/ndk" \
        "${ANDROID_HOME:-}/ndk" \
        "$HOME/Android/Sdk/ndk" \
        "$HOME/Library/Android/sdk/ndk" \
        "$HOME/android-sdk/ndk" \
        "/usr/local/lib/android/sdk/ndk"; do
        [[ -d "$base" ]] || continue
        latest="$(ls "$base" 2>/dev/null | sort -V | tail -n 1)"
        if [[ -n "$latest" && -d "$base/$latest" ]]; then
            printf '%s\n' "$base/$latest"
            return
        fi
    done
}

NDK="$(resolve_ndk || true)"
[[ -n "$NDK" ]] || die "Android NDK not found. Set ANDROID_NDK_HOME or install it from Android Studio → SDK Manager → NDK."

HOST_TAG="$(ls "$NDK/toolchains/llvm/prebuilt" 2>/dev/null | head -n 1)"
[[ -n "$HOST_TAG" ]] || die "unrecognised NDK layout: $NDK"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"

CC="$TOOLCHAIN/${TARGET_TRIPLE}${ANDROID_API}-clang"
AR="$TOOLCHAIN/llvm-ar"
RANLIB="$TOOLCHAIN/llvm-ranlib"
STRIP="$TOOLCHAIN/llvm-strip"
OBJCOPY="$TOOLCHAIN/llvm-objcopy"
OBJDUMP="$TOOLCHAIN/llvm-objdump"

for tool in "$CC" "$AR" "$RANLIB" "$STRIP" "$OBJCOPY" "$OBJDUMP"; do
    [[ -x "$tool" ]] || die "missing toolchain binary: $tool"
done

info "NDK:       $NDK"
info "compiler:  $CC"
info "target:    $TARGET_TRIPLE (API $ANDROID_API)"

mkdir -p "$BUILD_DIR" "$TALLOC_DIR" "$JNI_DIR" "$ROOT_DIR/third_party"

# ------------------------------------------------------------------- talloc
# PRoot needs libtalloc. Build it as a single translation unit to avoid
# Samba's waf/configure machinery, which does not cross-compile cleanly.
fetch_talloc() {
    if [[ -f "$TALLOC_DIR/talloc.c" && -f "$TALLOC_DIR/talloc.h" ]]; then
        info "talloc source present, reusing"
        return
    fi
    local tarball="$BUILD_DIR/talloc-$TALLOC_VERSION.tar.gz"
    info "fetching talloc $TALLOC_VERSION"
    curl -fL --retry 3 "https://download.samba.org/pub/talloc/talloc-$TALLOC_VERSION.tar.gz" -o "$tarball"
    local tmp
    tmp="$(mktemp -d)"
    tar xzf "$tarball" -C "$tmp"
    cp "$tmp/talloc-$TALLOC_VERSION/talloc.c" "$TALLOC_DIR/"
    cp "$tmp/talloc-$TALLOC_VERSION/talloc.h" "$TALLOC_DIR/"
    rm -rf "$tmp"

    # A minimal stand-in for Samba's replace.h: just enough HAVE_* defines and
    # helper macros for talloc.c to compile against bionic.
    cat > "$TALLOC_DIR/replace.h" <<'EOF'
#ifndef PROOTBOX_REPLACE_H
#define PROOTBOX_REPLACE_H

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>

#define TALLOC_BUILD_VERSION_MAJOR   2
#define TALLOC_BUILD_VERSION_MINOR   4
#define TALLOC_BUILD_VERSION_RELEASE 2

#define HAVE_STDARG_H 1
#define HAVE_VA_COPY 1
#define HAVE_UNISTD_H 1
#define HAVE_INTPTR_T 1
#define HAVE_CONSTRUCTOR_ATTRIBUTE 1

#define VALGRIND_MAKE_MEM_UNDEFINED(p, n) do { (void)(p); (void)(n); } while (0)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)   do { (void)(p); (void)(n); } while (0)
#define VALGRIND_MAKE_MEM_NOACCESS(p, n)  do { (void)(p); (void)(n); } while (0)

#ifndef ZERO_STRUCT
#define ZERO_STRUCT(x) memset((char *)&(x), 0, sizeof(x))
#endif
#ifndef discard_const
#define discard_const(ptr) ((void *)((uintptr_t)(ptr)))
#endif
#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif

#endif /* PROOTBOX_REPLACE_H */
EOF
}

build_talloc() {
    local out="$BUILD_DIR/libtalloc.a"
    if [[ -f "$out" ]]; then
        info "libtalloc.a present, reusing"
        return
    fi
    info "compiling libtalloc.a"
    "$CC" -c "$TALLOC_DIR/talloc.c" \
        -o "$BUILD_DIR/talloc.o" \
        -I"$TALLOC_DIR" \
        -fPIC -O2 -std=gnu99 -w \
        -DHAVE_STDARG_H=1 -DHAVE_VA_COPY=1 -DHAVE_UNISTD_H=1 -DHAVE_INTPTR_T=1
    "$AR" rcs "$out" "$BUILD_DIR/talloc.o"
    "$RANLIB" "$out"
}

# -------------------------------------------------------------------- proot
fetch_proot() {
    if [[ -d "$PROOT_DIR/src" ]]; then
        info "proot source present ($(git -C "$PROOT_DIR" describe --always 2>/dev/null || echo unknown)), reusing"
        info "  → remove third_party/proot to re-clone"
        return
    fi
    info "cloning $PROOT_REPO @ $PROOT_REF"
    git clone --depth 1 --branch "$PROOT_REF" "$PROOT_REPO" "$PROOT_DIR"
}

build_proot() {
    info "building proot"
    (
        cd "$PROOT_DIR/src"
        make clean >/dev/null 2>&1 || true
        make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" \
            CC="$CC" \
            STRIP="$STRIP" \
            OBJCOPY="$OBJCOPY" \
            OBJDUMP="$OBJDUMP" \
            CPPFLAGS="-D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I. -I$TALLOC_DIR -DARG_MAX=131072" \
            CFLAGS="-O2 -fPIE -Wall -Wno-unused-result" \
            LDFLAGS="-pie -Wl,-z,noexecstack -L$BUILD_DIR -ltalloc"
    )

    # Some proot revisions only build the loader through an explicit target.
    if [[ ! -f "$PROOT_DIR/src/loader/loader" ]]; then
        info "building loader target explicitly"
        ( cd "$PROOT_DIR/src" && \
          make loader/loader \
              CC="$CC" STRIP="$STRIP" OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP" \
              CPPFLAGS="-D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I. -I$TALLOC_DIR -DARG_MAX=131072" \
              CFLAGS="-O2 -fPIE -Wall" \
              LDFLAGS="-pie -Wl,-z,noexecstack -L$BUILD_DIR -ltalloc" )
    fi

    [[ -f "$PROOT_DIR/src/proot" ]] || die "build finished but src/proot is missing"
    [[ -f "$PROOT_DIR/src/loader/loader" ]] || die "build finished but src/loader/loader is missing (guest exec will fail on Android 10+)"
}

install_bins() {
    info "installing into jniLibs"
    "$STRIP" "$PROOT_DIR/src/proot" || warn "could not strip proot"
    "$STRIP" "$PROOT_DIR/src/loader/loader" || warn "could not strip loader"

    install -m 0755 "$PROOT_DIR/src/proot" "$JNI_DIR/libproot.so"
    install -m 0755 "$PROOT_DIR/src/loader/loader" "$JNI_DIR/libproot-loader.so"

    if [[ -f "$PROOT_DIR/src/loader/loader32" ]]; then
        install -m 0755 "$PROOT_DIR/src/loader/loader32" "$JNI_DIR/libproot-loader32.so"
    else
        info "no 32-bit loader (fine for a pure ARM64 container)"
    fi

    for file in "$JNI_DIR/libproot.so" "$JNI_DIR/libproot-loader.so"; do
        "$OBJDUMP" -f "$file" 2>/dev/null | grep -qi 'aarch64' \
            || die "$(basename "$file") is not an aarch64 ELF"
        info "  ✓ $(basename "$file") ($(wc -c < "$file" | tr -d ' ') bytes)"
    done
}

fetch_talloc
build_talloc
fetch_proot
build_proot
install_bins

cat <<EOF

PRoot is ready:
  android/app/src/main/jniLibs/arm64-v8a/libproot.so
  android/app/src/main/jniLibs/arm64-v8a/libproot-loader.so

Both are executed from ApplicationInfo.nativeLibraryDir at runtime; the app
passes libproot-loader.so to PRoot as PROOT_LOADER.

Next: scripts/build-rootfs.sh && flutter pub get
EOF
