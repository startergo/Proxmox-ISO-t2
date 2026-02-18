#!/usr/bin/env bash
# reset.sh — Remove all generated build artifacts
# Returns the repo to a clean state for a fresh build.
# Does NOT remove downloaded ISO or kernel packages (work/ directory kept).

set -e
source "$(dirname "$(readlink -f "$0")")/build.conf"

echo "[reset] Removing extracted ISO and squashfs work directories..."
rm -rf "${ISO_EXTRACT_DIR}"
rm -rf "${PVE_BASE_EXTRACT}"

echo "[reset] Removing output ISO..."
rm -f "${OUT_DIR}"/*.iso
rm -f "${OUT_DIR}"/*.sha256

echo "[reset] Removing GPG key and APT list written by prepare.sh..."
rm -f "${SCRIPT_DIR}/overlayfs/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg"
rm -f "${SCRIPT_DIR}/overlayfs/etc/apt/sources.list.d/t2.list"

echo ""
echo "[reset] Done. To also remove downloaded ISO and kernel packages:"
echo "        rm -rf ${WORK_DIR}/ ${PACKAGES_DIR}/"
echo ""
echo "        Run ./prepare.sh followed by sudo ./build.sh to rebuild."
