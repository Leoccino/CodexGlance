#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/manual"
MODULE_CACHE="${ROOT_DIR}/.build/module-cache"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

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

mkdir -p "${BUILD_DIR}" "${MODULE_CACHE}"

swiftc \
  -target "${TARGET}" \
  -sdk "${SDK_PATH}" \
  -module-cache-path "${MODULE_CACHE}" \
  -parse-as-library \
  -emit-library \
  -static \
  -emit-module \
  -module-name CodexGlanceCore \
  "${ROOT_DIR}/Sources/CodexGlanceCore/Models.swift" \
  "${ROOT_DIR}/Sources/CodexGlanceCore/DisplayFormatter.swift" \
  "${ROOT_DIR}/Sources/CodexGlanceCore/CodexRPCClient.swift" \
  "${ROOT_DIR}/Sources/CodexGlanceCore/CodexUsageFetcher.swift" \
  -emit-module-path "${BUILD_DIR}/CodexGlanceCore.swiftmodule" \
  -o "${BUILD_DIR}/libCodexGlanceCore.a"

swiftc \
  -target "${TARGET}" \
  -sdk "${SDK_PATH}" \
  -module-cache-path "${MODULE_CACHE}" \
  -I "${BUILD_DIR}" \
  -L "${BUILD_DIR}" \
  -lCodexGlanceCore \
  "${ROOT_DIR}/Sources/CodexGlance/AppDelegate.swift" \
  "${ROOT_DIR}/Sources/CodexGlance/main.swift" \
  -o "${BUILD_DIR}/CodexGlance"

echo "${BUILD_DIR}/CodexGlance"
