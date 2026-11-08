#!/usr/bin/env bash
#
# build-rootfs.sh — fetch an ARM64 Linux userland and stage it as
# assets/rootfs/rootfs.tar.gz (the archive the app unpacks on first launch).
#
# Why gzip and not xz: the runtime decompresses inside Dart, and dart:io ships
# a native gzip decoder while Android has no xz decoder available to an app.
# Both Alpine's minirootfs and Ubuntu Base are published as .tar.gz anyway.
#
# Usage:
#   scripts/build-rootfs.sh                      # Alpine (small, ~3 MB)
#   scripts/build-rootfs.sh --flavor ubuntu      # Ubuntu Base (~30 MB)
#   scripts/build-rootfs.sh --url <tarball-url>  # anything else
#   scripts/build-rootfs.sh --flavor alpine --version 3.20.3
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/assets/rootfs"
OUT_FILE="$OUT_DIR/rootfs.tar.gz"

FLAVOR="alpine"
VERSION=""
URL=""

ALPINE_INDEX="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/"
UBUNTU_INDEX="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/"

info()  { printf '\033[0;36m[build-rootfs]\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m[build-rootfs]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[0;31m[build-rootfs]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --flavor)  FLAVOR="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --url)     URL="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

command -v curl >/dev/null 2>&1 || die "curl is required"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo ""
    fi
}

latest_match() {
    # $1 = url, $2 = grep pattern, $3 = optional version filter
    local index="$1" pattern="$2" version="${3:-}"
    local listing
    listing="$(curl -fsSL "$index")" || die "could not read $index"
    if [[ -n "$version" ]]; then
        printf '%s\n' "$listing" \
            | grep -oE "$pattern" \
            | grep -F "$version" \
            | sort -V | tail -n 1
    else
        printf '%s\n' "$listing" \
            | grep -oE "$pattern" \
            | sort -V | tail -n 1
    fi
}

case "$FLAVOR" in
    alpine)
        if [[ -z "$URL" ]]; then
            info "resolving latest Alpine minirootfs for aarch64…"
            FILE="$(latest_match "$ALPINE_INDEX" 'alpine-minirootfs-[0-9.]+-aarch64\.tar\.gz' "$VERSION")"
            [[ -n "$FILE" ]] || die "could not find an Alpine aarch64 minirootfs in $ALPINE_INDEX"
            URL="${ALPINE_INDEX}${FILE}"
        fi
        ;;
    ubuntu)
        if [[ -z "$URL" ]]; then
            info "resolving latest Ubuntu Base arm64 tarball…"
            FILE="$(latest_match "$UBUNTU_INDEX" 'ubuntu-base-[0-9.]+-base-arm64\.tar\.gz' "$VERSION")"
            [[ -n "$FILE" ]] || die "could not find ubuntu-base arm64 in $UBUNTU_INDEX (pass --url)"
            URL="${UBUNTU_INDEX}${FILE}"
        fi
        ;;
    custom) ;;
    *) die "unknown --flavor '$FLAVOR' (alpine|ubuntu|custom)" ;;
esac

[[ -n "$URL" ]] || die "no URL resolved; pass --url <tarball>"

mkdir -p "$OUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE="$TMP_DIR/rootfs.$$.tar.gz"
info "downloading $URL"
curl -fL --retry 3 --progress-bar "$URL" -o "$ARCHIVE" || die "download failed"

DIGEST="$(sha256_of "$ARCHIVE")"
SIZE="$(wc -c < "$ARCHIVE" | tr -d ' ')"

# Verify against the upstream checksum file when the mirror publishes one.
VERIFIED="false"
for SUM_URL in "${URL}.sha256" "$(dirname "$URL")/SHA256SUMS"; do
    if curl -fsSL "$SUM_URL" -o "$TMP_DIR/sums" 2>/dev/null; then
        NAME="$(basename "$URL")"
        EXPECTED="$(awk -v n="$NAME" '$0 ~ n {print $1}' "$TMP_DIR/sums" | head -n 1)"
        if [[ -n "$EXPECTED" ]]; then
            if [[ "$EXPECTED" == "$DIGEST" ]]; then
                VERIFIED="true"
                info "sha256 verified against $SUM_URL"
            else
                die "checksum mismatch! expected $EXPECTED, got $DIGEST"
            fi
            break
        fi
    fi
done
[[ "$VERIFIED" == "true" ]] || warn "no upstream checksum available; sha256 recorded for reference"

# Sanity check: it must be a real gzip tar with an /etc or /bin inside.
file "$ARCHIVE" 2>/dev/null | grep -qi 'gzip' || warn "archive does not look like gzip (continuing)"
tar -tzf "$ARCHIVE" ./etc >/dev/null 2>&1 || tar -tzf "$ARCHIVE" etc >/dev/null 2>&1 \
    || warn "archive does not contain an etc/ directory — is this a rootfs?"

install -m 0644 "$ARCHIVE" "$OUT_FILE"

cat > "$OUT_DIR/rootfs.json" <<EOF
{
  "flavor": "$FLAVOR",
  "source": "$URL",
  "sha256": "$DIGEST",
  "bytes": $SIZE,
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

info "installed $(basename "$OUT_FILE") ($((SIZE / 1024 / 1024)) MiB, sha256 ${DIGEST:0:16}…)"
info "next: scripts/build-proot.sh && flutter pub get && flutter build apk"
case "$FLAVOR" in
    alpine) info "Alpine ships /bin/sh (busybox ash) but not bash; run 'apk add bash' inside the terminal if you want bash." ;;
    ubuntu) info "Ubuntu Base ships /bin/bash; the app will pick it automatically." ;;
esac
