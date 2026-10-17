#!/bin/bash
# Build the led-ugreen kernel module for a specific Unraid release.
#
#   ./source/build-kmod.sh 7.3.3
#   ./source/build-kmod.sh 7.3.3 https://releases.unraid.net/dl/stable/.../unRAIDServer-7.3.3-x86_64.zip
#
# Why this exists: a module built against the wrong kernel *configuration* loads
# fine (vermagic matches) but corrupts memory and hard-locks the NAS
# (see miskcoo/ugreen_leds_controller#129). So this script always builds against
# the exact config and patches shipped inside the official Unraid image:
#   1. download the official Unraid zip (checksum verified)
#   2. pull /usr/src/linux-<ver>-Unraid (config + patches) out of bzmodules
#   3. download the matching vanilla kernel from kernel.org (checksum verified)
#   4. apply Unraid's patches + config, build the module, verify it
#   5. package it as packages/kmod/<kernel>/ugreen_leds-<kernel>.txz (+ .md5)
#
# Requirements (Debian/Ubuntu): build-essential bc flex bison libelf-dev libssl-dev
#   cpio squashfs-tools zstd xz-utils unzip curl jq python3 kmod
set -euo pipefail

UNRAID_VER="${1:?usage: $0 <unraid-version> [zip-url]}"
ZIP_URL="${2:-}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$(mktemp -d /tmp/ugreen-kmod.XXXXXX)}"
JOBS="$(nproc)"
mkdir -p "${WORK}"
echo ">> work dir: ${WORK}"

# --- 1. Unraid image ------------------------------------------------------
ZIP_MD5=""
if [[ -z "${ZIP_URL}" ]]; then
  RELEASES="$(curl -fsSL "https://releases.unraid.net/json" 2>/dev/null || true)"
  ZIP_URL="$(jq -r --arg v "${UNRAID_VER}" '.[] | select(.version==$v) | .url' <<< "${RELEASES}" 2>/dev/null | head -1 || true)"
  ZIP_MD5="$(jq -r --arg v "${UNRAID_VER}" '.[] | select(.version==$v) | .md5' <<< "${RELEASES}" 2>/dev/null | head -1 || true)"
fi
[[ -n "${ZIP_URL}" && "${ZIP_URL}" != null ]] || { echo "!! could not find download URL for Unraid ${UNRAID_VER}; pass it as 2nd argument"; exit 1; }

if [[ ! -f "${WORK}/unraid.zip" ]]; then
  echo ">> downloading Unraid ${UNRAID_VER}"
  curl -fSL --retry 3 -o "${WORK}/unraid.zip" "${ZIP_URL}"
fi
if [[ -n "${ZIP_MD5:-}" && "${ZIP_MD5}" != null ]]; then
  echo "${ZIP_MD5}  ${WORK}/unraid.zip" | md5sum -c -
fi
(cd "${WORK}" && unzip -oq unraid.zip bzroot bzmodules bzimage)

# --- 2. kernel config + patches from bzmodules / tools from bzroot ---------
rm -rf "${WORK:?}/usr" "${WORK:?}/root"
unsquashfs -q -f -d "${WORK}/usr" "${WORK}/bzmodules" 'src' >/dev/null
SRC_DIR="$(ls -d "${WORK}"/usr/src/linux-*-Unraid | head -1)"
KERNEL_V="$(basename "${SRC_DIR}" | sed 's/^linux-//')"        # e.g. 6.18.54-Unraid
BASE_V="${KERNEL_V%%-*}"                                          # e.g. 6.18.54
echo ">> Unraid ${UNRAID_VER} ships kernel ${KERNEL_V}"

# bzroot = uncompressed microcode cpio + compressed root cpio; we need sbin/makepkg + lib/modules
mkdir -p "${WORK}/root"
python3 - "${WORK}/bzroot" "${WORK}/rootfs.cpio.z" <<'EOF'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'TRAILER!!!') + 10
while d[i] == 0: i += 1
open(sys.argv[2], 'wb').write(d[i:])
EOF
case "$(head -c4 "${WORK}/rootfs.cpio.z" | od -An -tx1 | tr -d " \n")" in
  28b52ffd) DEC="zstd -dc";;
  fd377a58) DEC="xz -dc";;
  *) DEC="gzip -dc";;
esac
(cd "${WORK}/root" && ${DEC} "${WORK}/rootfs.cpio.z" | cpio -idm --quiet 'sbin/makepkg' 'lib/modules/*' 2>/dev/null) || true
MAKEPKG="${WORK}/root/sbin/makepkg"
[[ -x "${MAKEPKG}" ]] || { echo "!! makepkg not found in bzroot"; exit 1; }

# --- 3. vanilla kernel source --------------------------------------------
MAJOR="${BASE_V%%.*}"
TARBALL="linux-${BASE_V}.tar.xz"
if [[ ! -f "${WORK}/${TARBALL}" ]]; then
  echo ">> downloading ${TARBALL}"
  curl -fSL --retry 3 -o "${WORK}/${TARBALL}" "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"
fi
EXPECTED="$(curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/sha256sums.asc" | awk -v f="${TARBALL}" '$2==f{print $1}')"
echo "${EXPECTED}  ${WORK}/${TARBALL}" | sha256sum -c -

# --- 4. configure + build -------------------------------------------------
KSRC="${WORK}/linux"
rm -rf "${KSRC}" && mkdir -p "${KSRC}"
tar -xJf "${WORK}/${TARBALL}" -C "${KSRC}" --strip-components=1
for p in "${SRC_DIR}"/*.patch; do
  [[ -e "$p" ]] || continue
  echo "   patch $(basename "$p")"
  patch -d "${KSRC}" -p1 -s --forward < "$p"
done
[[ -d "${SRC_DIR}/drivers" ]] && cp -r "${SRC_DIR}/drivers/." "${KSRC}/drivers/"
cp "${SRC_DIR}/config" "${KSRC}/.config"
make -C "${KSRC}" olddefconfig >/dev/null
# make sure nothing ABI-relevant drifted (only compiler-capability symbols may differ)
DRIFT="$(diff <(grep -v '^#' "${SRC_DIR}/config" | sort) <(grep -v '^#' "${KSRC}/.config" | sort) \
  | grep -E '^[<>]' | grep -vE 'CONFIG_(CC_|GCC_|AS_|LD_|PAHOLE_|RUSTC_|RUST_IS_|CLANG_|TOOLS_SUPPORT)' || true)"
if [[ -n "${DRIFT}" ]]; then
  echo "!! kernel config drifted from Unraid's config (ABI risk):"; echo "${DRIFT}"; exit 1
fi
make -C "${KSRC}" -j"${JOBS}" modules_prepare >/dev/null
grep -q "\"${KERNEL_V}\"" "${KSRC}/include/generated/utsrelease.h" || { echo "!! release string mismatch"; exit 1; }

KMOD_BUILD="${WORK}/kmod"
rm -rf "${KMOD_BUILD}" && cp -r "${REPO_DIR}/source/kmod" "${KMOD_BUILD}"
make -C "${KSRC}" M="${KMOD_BUILD}" KBUILD_MODPOST_WARN=1 -j"${JOBS}" modules 2>&1 | grep -v 'undefined!\|Module.symvers\|unresolved symbol\|KBUILD_MODPOST_WARN\|modversions' || true
KO="${KMOD_BUILD}/led-ugreen.ko"
[[ -f "${KO}" ]] || { echo "!! build failed"; exit 1; }

# --- verification ---------------------------------------------------------
SHIPPED="${WORK}/root/lib/modules/${KERNEL_V}"
REF_VERMAGIC="$(modinfo -F vermagic "$(find "${SHIPPED}" -name 'led-class.ko*' | head -1)")"
OUR_VERMAGIC="$(modinfo -F vermagic "${KO}")"
[[ "${REF_VERMAGIC}" == "${OUR_VERMAGIC}" ]] || { echo "!! vermagic mismatch: '${OUR_VERMAGIC}' vs '${REF_VERMAGIC}'"; exit 1; }
echo ">> vermagic OK: ${OUR_VERMAGIC}"

# struct led_classdev size must match the shipped kernel (the lockup bug).
# Unraid's own input-leds.ko stores `handle` right after its led_classdev, so its offset == sizeof.
IL="$(find "${SHIPPED}" -name 'input-leds.ko*' | head -1)"
if [[ -n "${IL}" ]]; then
  xz -dc "${IL}" > "${WORK}/input-leds.ko" 2>/dev/null || cp "${IL}" "${WORK}/input-leds.ko"
  # first (%rdi) displacement in input_leds_brightness_get() is input_led->handle,
  # which sits directly after the embedded struct led_classdev
  REF_SIZE="$(objdump -d "${WORK}/input-leds.ko" | awk '/<input_leds_brightness_get>:/,/^$/' \
    | grep -oE '0x[0-9a-f]+\(%rdi\)' | grep -oE '^0x[0-9a-f]+' \
    | while read -r h; do v=$((h)); if (( v >= 384 && v < 768 )); then echo "$v"; fi; done | sort -n | head -1 || true)"
  mkdir -p "${WORK}/sz"
  cat > "${WORK}/sz/sz.c" <<EOF
#include <linux/module.h>
#include <linux/leds.h>
static int __init t(void){ BUILD_BUG_ON(sizeof(struct led_classdev) != ${REF_SIZE:-0}); return 0; }
module_init(t); MODULE_LICENSE("GPL");
EOF
  echo 'obj-m += sz.o' > "${WORK}/sz/Makefile"
  if [[ -n "${REF_SIZE}" ]] && make -C "${KSRC}" M="${WORK}/sz" KBUILD_MODPOST_WARN=1 modules >/dev/null 2>&1; then
    echo ">> sizeof(struct led_classdev) == ${REF_SIZE} matches shipped kernel"
  else
    echo "!! struct led_classdev size check FAILED (expected ${REF_SIZE:-unknown}) - refusing to package"; exit 1
  fi
fi

# all undefined symbols must resolve against the shipped kernel + modules
TMPMOD="${WORK}/depmod-test"
rm -rf "${TMPMOD}" && mkdir -p "${TMPMOD}/lib/modules"
cp -a "${SHIPPED}" "${TMPMOD}/lib/modules/"
rm -f "${TMPMOD}/lib/modules/${KERNEL_V}/build"
mkdir -p "${TMPMOD}/lib/modules/${KERNEL_V}/extra"
xz --check=crc32 --lzma2 -c "${KO}" > "${TMPMOD}/lib/modules/${KERNEL_V}/extra/led-ugreen.ko.xz"
UNRES="$(depmod -b "${TMPMOD}" -e -F "${SRC_DIR}/System.map" "${KERNEL_V}" 2>&1 || true)"
[[ -z "${UNRES}" ]] || { echo "!! depmod reported problems:"; echo "${UNRES}"; exit 1; }
grep 'led-ugreen' "${TMPMOD}/lib/modules/${KERNEL_V}/modules.dep"

# --- 5. package -----------------------------------------------------------
PKG_ROOT="${WORK}/pkg"
rm -rf "${PKG_ROOT}" && mkdir -p "${PKG_ROOT}/lib/modules/${KERNEL_V}/extra" "${PKG_ROOT}/install"
cp "${TMPMOD}/lib/modules/${KERNEL_V}/extra/led-ugreen.ko.xz" "${PKG_ROOT}/lib/modules/${KERNEL_V}/extra/"
UPSTREAM="$(cat "${REPO_DIR}/source/kmod/UPSTREAM" 2>/dev/null || echo unknown)"
cat > "${PKG_ROOT}/install/slack-desc" <<EOF
           |-----handy-ruler------------------------------------------------------|
ugreen_leds: ugreen_leds (UGREEN NAS LED kernel module)
ugreen_leds:
ugreen_leds: led-ugreen.ko built for Unraid ${UNRAID_VER} (kernel ${KERNEL_V})
ugreen_leds: against the exact kernel config shipped in the Unraid image.
ugreen_leds: Source: https://github.com/miskcoo/ugreen_leds_controller
ugreen_leds: Upstream commit: ${UPSTREAM}
ugreen_leds:
EOF
chmod 755 "${PKG_ROOT}" "${PKG_ROOT}/lib" "${PKG_ROOT}/lib/modules" "${PKG_ROOT}/lib/modules/${KERNEL_V}" "${PKG_ROOT}/lib/modules/${KERNEL_V}/extra" "${PKG_ROOT}/install"
chmod 644 "${PKG_ROOT}/lib/modules/${KERNEL_V}/extra/led-ugreen.ko.xz" "${PKG_ROOT}/install/slack-desc"

OUT_DIR="${REPO_DIR}/packages/kmod/${KERNEL_V}"
mkdir -p "${OUT_DIR}"
# Slackware naming: name-version-arch-build  (e.g. ugreen_leds-6.18.54_Unraid-x86_64-1.txz)
OUT="${OUT_DIR}/ugreen_leds-${KERNEL_V//-/_}-x86_64-1.txz"
rm -f "${OUT_DIR}"/ugreen_leds-*.txz "${OUT_DIR}"/ugreen_leds-*.txz.md5
rm -f "${OUT}"
(cd "${PKG_ROOT}" && fakeroot_cmd="" && [[ $EUID -ne 0 ]] && command -v fakeroot >/dev/null && fakeroot_cmd=fakeroot; \
  ${fakeroot_cmd} "${MAKEPKG}" -l n -c y "${OUT}" >/dev/null)
md5sum "${OUT}" | awk '{print $1}' > "${OUT}.md5"
echo "${UNRAID_VER}" > "${OUT_DIR}/UNRAID_VERSION"
echo ">> built ${OUT}"
echo ">> md5 $(cat "${OUT}.md5")"
