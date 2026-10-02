#!/bin/bash
set -euo pipefail

ACTION="${1:-help}"
case "$ACTION" in
  help|--help|-h)
    printf 'Usage: quota.sh {check|signing-setup|build|query|query-all|install|open}\nquery checks Codex; query-all checks all built-in sources. No reset command is provided.\n'
    exit 0 ;;
  check|signing-setup|build|query|query-all|install|open) ;;
  *) printf 'Unknown command. Use check, signing-setup, build, query, query-all, install or open.\n' >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  printf 'Unexpected extra arguments.\n' >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  printf 'AI 额度 requires a local Mac (macOS 13 or newer).\n' >&2
  exit 1
fi
MAJOR_VERSION="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$MAJOR_VERSION" -lt 13 ]]; then
  printf 'macOS 13 or newer is required.\n' >&2
  exit 1
fi

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_SOURCE="$SKILL_DIR/assets/native"
INSTALL_APP="$HOME/Applications/Codex额度.app"
EXPECTED_ID='local.huian.codex-quota'
EXPECTED_VERSION='0.3.5'

valid_app() {
  local candidate="$1"
  [[ ! -L "$candidate" && -x "$candidate/Contents/MacOS/CodexQuota" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null)" == "$EXPECTED_ID" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/Contents/Info.plist" 2>/dev/null)" == "$EXPECTED_VERSION" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$candidate" >/dev/null 2>&1
}

if [[ "$ACTION" == open ]]; then
  if valid_app "$INSTALL_APP"; then
    /usr/bin/open "$INSTALL_APP"
    exit 0
  fi
  printf 'Install the companion first with quota.sh install. No existing app was changed.\n' >&2
  exit 1
fi

# Use the stable installed path for read queries so local login access survives updates.
if [[ "$ACTION" == query || "$ACTION" == query-all ]] && valid_app "$INSTALL_APP"; then
  if [[ "$ACTION" == query ]]; then
    exec "$INSTALL_APP/Contents/MacOS/CodexQuota" --diagnose
  fi
  exec "$INSTALL_APP/Contents/MacOS/CodexQuota" --diagnose-all
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'Missing python3. Install Python 3 before setting up signing or building.\n' >&2
  exit 1
fi
if [[ "$ACTION" == signing-setup ]]; then
  python3 "$NATIVE_SOURCE/scripts/local-signing.py" setup
  exit 0
fi

for required in swift iconutil codesign shasum; do
  if ! command -v "$required" >/dev/null 2>&1; then
    printf 'Missing %s. Install Xcode Command Line Tools before building.\n' "$required" >&2
    exit 1
  fi
done
if ! xcrun --find swift >/dev/null 2>&1; then
  printf 'Xcode Command Line Tools must be configured before building.\n' >&2
  exit 1
fi
if [[ "$ACTION" == check ]]; then
  printf 'macOS, Swift and Python 3 prerequisites are available. signing-setup initializes or verifies the fixed local signing identity; query checks Codex; query-all checks all built-in sources.\n'
  exit 0
fi

# Include contents and paths so updated source cannot reuse a stale cached app.
SOURCE_HASH="$(cd "$NATIVE_SOURCE" && find Package.swift Sources scripts -type d -name '__pycache__' -prune -o -type f ! -name '*.pyc' ! -name '*.pyo' -exec shasum -a 256 {} \; | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1)"
CACHE_ROOT="$HOME/Library/Caches/CodexQuota"
mkdir -p "$CACHE_ROOT"
chmod 700 "$CACHE_ROOT"
CACHED_APP="$CACHE_ROOT/$SOURCE_HASH/Codex额度.app"
if ! valid_app "$CACHED_APP"; then
  WORK_DIR="$(mktemp -d "$CACHE_ROOT/build.XXXXXX")"
  trap 'rm -rf "$WORK_DIR"' EXIT
  cp "$NATIVE_SOURCE/Package.swift" "$WORK_DIR/"
  cp -R "$NATIVE_SOURCE/Sources" "$NATIVE_SOURCE/Tests" "$NATIVE_SOURCE/scripts" "$WORK_DIR/"
  bash "$WORK_DIR/scripts/build-app.sh" >&2
  valid_app "$WORK_DIR/dist/Codex额度.app"
  mkdir -p "$CACHE_ROOT/$SOURCE_HASH"
  # Another build may have completed first; don't overwrite a valid cache.
  if ! valid_app "$CACHED_APP"; then
    if [[ -e "$CACHED_APP" || -L "$CACHED_APP" ]]; then
      printf 'Invalid cached app; inspect %s before replacing it.\n' "$CACHED_APP" >&2
      exit 1
    fi
    /usr/bin/ditto "$WORK_DIR/dist/Codex额度.app" "$CACHED_APP"
  fi
fi
valid_app "$CACHED_APP"

case "$ACTION" in
  build) printf '%s\n' "$CACHED_APP" ;;
  query) "$CACHED_APP/Contents/MacOS/CodexQuota" --diagnose ;;
  query-all) "$CACHED_APP/Contents/MacOS/CodexQuota" --diagnose-all ;;
  install)
    if [[ -e "$INSTALL_APP" || -L "$INSTALL_APP" ]]; then
      if valid_app "$INSTALL_APP"; then
        printf 'Already installed: %s\n' "$INSTALL_APP"
        exit 0
      fi
      printf 'An existing app is present at %s. It was not replaced.\n' "$INSTALL_APP" >&2
      exit 1
    fi
    mkdir -p "$HOME/Applications"
    /usr/bin/ditto "$CACHED_APP" "$INSTALL_APP"
    valid_app "$INSTALL_APP"
    printf 'Installed: %s\n' "$INSTALL_APP"
    ;;
esac
