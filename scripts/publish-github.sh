#!/usr/bin/env bash
#
# publish-github.sh — initialise git, commit the whole project, create a new
# GitHub repository and push to it.
#
# Prerequisites (one time):
#   - git installed and configured:   git config --global user.name "…"
#                                     git config --global user.email "…"
#   - GitHub CLI installed: https://cli.github.com
#   - authenticated:                  gh auth login
#
# Usage:
#   scripts/publish-github.sh                        # public repo "prootbox"
#   scripts/publish-github.sh --name my-sandbox
#   scripts/publish-github.sh --private
#   scripts/publish-github.sh --push-only            # remote already exists
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_NAME="prootbox"
VISIBILITY="public"
BRANCH="main"
DESCRIPTION="Self-contained PRoot Linux sandbox for Android, built with Flutter"
COMMIT_MESSAGE="ProotBox: embedded PRoot Linux sandbox for Android"
PUSH_ONLY=0

info() { printf '\033[0;36m[publish]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[publish]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[publish]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)      REPO_NAME="${2:-}"; shift 2 ;;
        --private)   VISIBILITY="private"; shift ;;
        --public)    VISIBILITY="public"; shift ;;
        --branch)    BRANCH="${2:-}"; shift 2 ;;
        --message)   COMMIT_MESSAGE="${2:-}"; shift 2 ;;
        --description) DESCRIPTION="${2:-}"; shift 2 ;;
        --push-only) PUSH_ONLY=1; shift ;;
        -h|--help)   sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

cd "$ROOT_DIR"

command -v git >/dev/null 2>&1 || die "git is not installed"

# ------------------------------------------------------------ 1. git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    info "initialising repository on branch $BRANCH"
    git init >/dev/null
    git symbolic-ref HEAD "refs/heads/$BRANCH"
else
    info "repository already initialised"
fi

if ! git config user.email >/dev/null 2>&1; then
    cat >&2 <<'EOF'
[publish] git has no author identity configured. Run once:

    git config --global user.name  "Your Name"
    git config --global user.email "you@example.com"

Then re-run this script.
EOF
    exit 1
fi

# ------------------------------------------------------- 2. stage + commit
if [[ "$PUSH_ONLY" == "0" ]]; then
    info "staging project files"
    git add -A

    # Guard rails: generated binaries must never enter the repository.
    for forbidden in \
        "assets/rootfs/rootfs.tar.gz" \
        "assets/rootfs/rootfs.tar.xz" \
        "android/app/src/main/jniLibs/arm64-v8a/libproot.so" \
        "android/app/src/main/jniLibs/arm64-v8a/libproot-loader.so"; do
        if git ls-files --cached --error-unmatch "$forbidden" >/dev/null 2>&1; then
            warn "$forbidden is tracked — removing from the index (it is generated)"
            git rm --cached -q "$forbidden"
        fi
    done

    if git diff --cached --quiet; then
        info "nothing new to commit"
    else
        info "committing"
        git commit -q -m "$COMMIT_MESSAGE"
    fi
fi

# ------------------------------------------------------------- 3. publish
if ! command -v gh >/dev/null 2>&1; then
    cat <<EOF

GitHub CLI (gh) is not installed, so the remote must be created by hand:

  1. create an empty repository named "$REPO_NAME" on github.com
     (do NOT initialise it with a README)
  2. then run:

     git remote add origin https://github.com/<you>/$REPO_NAME.git
     git push -u origin $BRANCH

EOF
    exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
    cat <<'EOF'

GitHub CLI is installed but not authenticated. Run:

    gh auth login

…then re-run this script (or use --push-only if the remote already exists).

EOF
    exit 1
fi

if git remote get-url origin >/dev/null 2>&1; then
    info "pushing to existing origin (origin/$BRANCH)"
    git push -u origin "$BRANCH"
else
    info "creating GitHub repository $REPO_NAME ($VISIBILITY)"
    gh repo create "$REPO_NAME" \
        "--$VISIBILITY" \
        --source=. \
        --remote=origin \
        --description "$DESCRIPTION" \
        --push
fi

URL="$(gh repo view --json url -q .url 2>/dev/null || true)"
cat <<EOF

Done.

  repository: ${URL:-<created>}
  branch:     $BRANCH
  commit:     $(git rev-parse --short HEAD 2>/dev/null || echo none)

Reminder: the rootfs archive and the proot binaries are gitignored on purpose.
A fresh clone must run scripts/prepare-assets.sh before it can build a working
APK. See docs/BUILDING.md.
EOF
