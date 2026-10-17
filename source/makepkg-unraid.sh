#!/bin/bash
# Build the userspace package (the ugreen-leds daemon) into packages/.
#   ./source/makepkg-unraid.sh [version] [path-to-slackware-makepkg]
# On an Unraid box makepkg is /sbin/makepkg; build-kmod.sh also extracts one
# from the Unraid image into $WORK/root/sbin/makepkg.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_NAME="ugreenleds-driver"
VERSION="${1:-$(date +'%Y.%m.%d')}"
MAKEPKG="${2:-/sbin/makepkg}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
install -d -m 755 "${TMP_DIR}/usr" "${TMP_DIR}/usr/bin"
install -m 755 "${REPO_DIR}/source/usr/bin/ugreen-leds" "${TMP_DIR}/usr/bin/ugreen-leds"
chmod 755 "${TMP_DIR}"

OUT="${REPO_DIR}/packages/${PLUGIN_NAME}-${VERSION}.txz"
rm -f "${OUT}"
(cd "${TMP_DIR}" && "${MAKEPKG}" -l n -c y "${OUT}" >/dev/null)
md5sum "${OUT}" | awk '{print $1}' > "${OUT}.md5"
echo "built ${OUT} md5 $(cat "${OUT}.md5")"
