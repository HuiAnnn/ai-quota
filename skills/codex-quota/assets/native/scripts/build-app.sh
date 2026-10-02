#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for required_command in swift iconutil codesign python3; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf '缺少命令：%s。请先安装 Xcode Command Line Tools（xcode-select --install）。\n' "$required_command" >&2
    exit 1
  fi
done

SIGNING_IDENTITY="$(python3 "$ROOT_DIR/scripts/local-signing.py" identity)"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

swift build --configuration release
BIN_DIR="$(swift build --configuration release --show-bin-path)"
if [[ ! -x "$BIN_DIR/CodexQuota" ]]; then
  printf '未找到编译产物：%s/CodexQuota\n' "$BIN_DIR" >&2
  exit 1
fi

DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.CodexQuota.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_BUNDLE="$STAGING_DIR/Codex额度.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/CodexQuota" "$APP_BUNDLE/Contents/MacOS/CodexQuota"
chmod 755 "$APP_BUNDLE/Contents/MacOS/CodexQuota"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.huian.codex-quota</string>
  <key>CFBundleName</key><string>AI 额度</string>
  <key>CFBundleDisplayName</key><string>AI 额度</string>
  <key>CFBundleExecutable</key><string>CodexQuota</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.5</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swift "$ROOT_DIR/scripts/generate-icon.swift" "$STAGING_DIR/AppIcon.iconset"
iconutil --convert icns "$STAGING_DIR/AppIcon.iconset" --output "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN" --timestamp=none "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

OUTPUT_APP="$DIST_DIR/Codex额度.app"
if [[ -e "$OUTPUT_APP" ]]; then
  rm -rf "$OUTPUT_APP"
fi
mv "$APP_BUNDLE" "$OUTPUT_APP"
printf '\n构建完成：%s\n' "$OUTPUT_APP"
