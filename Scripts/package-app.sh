#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/.build/CodexGlance.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

"${ROOT_DIR}/Scripts/build.sh" >/dev/null

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
cp "${ROOT_DIR}/.build/manual/CodexGlance" "${MACOS_DIR}/CodexGlance"

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CodexGlance</string>
  <key>CFBundleIdentifier</key>
  <string>local.codexglance</string>
  <key>CFBundleName</key>
  <string>CodexGlance</string>
  <key>CFBundleDisplayName</key>
  <string>CodexGlance</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

echo "${APP_DIR}"
