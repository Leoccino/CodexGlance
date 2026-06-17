#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="${ROOT_DIR}/.build/release"
CODEXGLANCE_VERSION="${CODEXGLANCE_VERSION:-0.1.1}"
export CODEXGLANCE_VERSION
APP_DIR="$("${ROOT_DIR}/Scripts/package-app.sh")"
ZIP_PATH="${RELEASE_DIR}/CodexGlance.app.zip"

mkdir -p "${RELEASE_DIR}"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true
fi

find "${APP_DIR}" -name '._*' -type f -delete

rm -f "${ZIP_PATH}"
(
  cd "$(dirname "${APP_DIR}")"
  zip -qry -X "${ZIP_PATH}" "$(basename "${APP_DIR}")"
)

echo "${ZIP_PATH}"
