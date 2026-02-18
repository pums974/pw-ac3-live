#!/usr/bin/env bash
set -euo pipefail

# Build and package pw-ac3-live for Steam Deck (SteamOS is x86_64 Linux).
# Output:
#   dist/pw-ac3-live-steamdeck-<version>/
#   dist/pw-ac3-live-steamdeck-<version>.tar.gz

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_TRIPLE="${TARGET_TRIPLE:-x86_64-unknown-linux-gnu}"
BUILD_PROFILE="${BUILD_PROFILE:-release}"
APP_NAME="pw-ac3-live"
APP_VERSION="$(awk -F'"' '/^version = / { print $2; exit }' "${REPO_ROOT}/Cargo.toml")"

if [[ -z "${APP_VERSION}" ]]; then
    echo "Failed to detect version from Cargo.toml" >&2
    exit 1
fi

DIST_DIR="${REPO_ROOT}/dist"
PKG_DIR="${DIST_DIR}/${APP_NAME}-steamdeck-${APP_VERSION}"
ARCHIVE_PATH="${DIST_DIR}/${APP_NAME}-steamdeck-${APP_VERSION}.tar.gz"

echo "==> Building ${APP_NAME} (${BUILD_PROFILE}) for ${TARGET_TRIPLE}"
if [[ "${BUILD_PROFILE}" == "release" ]]; then
    cargo build --release --target "${TARGET_TRIPLE}"
else
    cargo build --profile "${BUILD_PROFILE}" --target "${TARGET_TRIPLE}"
fi

BIN_PATH="${REPO_ROOT}/target/${TARGET_TRIPLE}/${BUILD_PROFILE}/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "Built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Staging package at ${PKG_DIR}"
rm -rf "${PKG_DIR}"
mkdir -p "${PKG_DIR}/bin"

cp "${BIN_PATH}" "${PKG_DIR}/bin/${APP_NAME}"
cp -r "${REPO_ROOT}/scripts" "${PKG_DIR}/"
cp "${REPO_ROOT}/README.md" "${PKG_DIR}/README.md"

cat > "${PKG_DIR}/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${SCRIPT_DIR}/bin:${PATH}"
exec "${SCRIPT_DIR}/bin/pw-ac3-live" "$@"
EOF

cat > "${PKG_DIR}/STEAM_DECK_NOTES.txt" <<'EOF'
Runtime requirements on Steam Deck:
- ffmpeg
- PipeWire + WirePlumber (default on SteamOS desktop mode)
- CLI tools used by launcher: pactl, pw-link, wpctl

Quick start on Deck (desktop mode):
1) tar -xzf pw-ac3-live-steamdeck-*.tar.gz
2) cd pw-ac3-live-steamdeck-*
3) chmod +x run.sh scripts/*.sh
4) ./scripts/launch_live.sh
EOF

chmod +x "${PKG_DIR}/run.sh" "${PKG_DIR}/bin/${APP_NAME}" "${PKG_DIR}/scripts/"*.sh

echo "==> Creating archive ${ARCHIVE_PATH}"
mkdir -p "${DIST_DIR}"
tar -C "${DIST_DIR}" -czf "${ARCHIVE_PATH}" "$(basename "${PKG_DIR}")"

echo
echo "Package ready:"
echo "  ${ARCHIVE_PATH}"
