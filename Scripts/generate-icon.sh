#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/icon"
MODULE_CACHE="${ROOT_DIR}/.build/module-cache"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
ICON_PATH="${BUILD_DIR}/CodexGlanceIcon.png"

ARCH="$(/usr/bin/uname -m)"
case "${ARCH}" in
  arm64)
    TARGET="arm64-apple-macos13.0"
    ;;
  x86_64)
    TARGET="x86_64-apple-macos13.0"
    ;;
  *)
    echo "Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${MODULE_CACHE}"

swiftc \
  -target "${TARGET}" \
  -sdk "${SDK_PATH}" \
  -module-cache-path "${MODULE_CACHE}" \
  "${ROOT_DIR}/Scripts/IconGenerator.swift" \
  -o "${BUILD_DIR}/IconGenerator"

"${BUILD_DIR}/IconGenerator" "${BUILD_DIR}"
xattr -c "${ICON_PATH}" 2>/dev/null || true

echo "${ICON_PATH}"
