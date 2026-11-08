#!/usr/bin/env bash
#
# prepare-assets.sh — one command that produces every binary artifact the app
# needs at runtime:
#
#   assets/rootfs/rootfs.tar.gz                             (Linux userland)
#   android/app/src/main/jniLibs/arm64-v8a/libproot.so      (PRoot)
#   android/app/src/main/jniLibs/arm64-v8a/libproot-loader.so
#
# Usage:
#   scripts/prepare-assets.sh                 # rootfs + proot
#   scripts/prepare-assets.sh --rootfs-only
#   scripts/prepare-assets.sh --proot-only
#   scripts/prepare-assets.sh --flavor ubuntu
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DO_ROOTFS=1
DO_PROOT=1
ROOTFS_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs-only) DO_PROOT=0; shift ;;
        --proot-only)  DO_ROOTFS=0; shift ;;
        --flavor|--url|--version)
            ROOTFS_ARGS+=("$1" "${2:-}"); shift 2 ;;
        -h|--help)
            sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ "$DO_ROOTFS" == "1" ]]; then
    echo "── root filesystem ───────────────────────────────────────────────"
    "$ROOT_DIR/scripts/build-rootfs.sh" "${ROOTFS_ARGS[@]+"${ROOTFS_ARGS[@]}"}"
fi

if [[ "$DO_PROOT" == "1" ]]; then
    echo
    echo "── proot ─────────────────────────────────────────────────────────"
    "$ROOT_DIR/scripts/build-proot.sh"
fi

cat <<'EOF'

── artefacts ─────────────────────────────────────────────────────────────
EOF
ls -lh "$ROOT_DIR/assets/rootfs"/*.tar.gz 2>/dev/null || true
ls -lh "$ROOT_DIR/android/app/src/main/jniLibs/arm64-v8a"/*.so 2>/dev/null || true
cat <<'EOF'

Now run:  flutter pub get  then  flutter run / flutter build apk
EOF
