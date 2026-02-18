#!/usr/bin/env bash
# prepare.sh — Download Proxmox VE ISO and T2 kernel packages
# Run this once before build.sh. Slow downloads are cached between rebuilds.
# Does NOT require root.

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/build.conf"

log() { echo "[prepare] $*"; }

# ── Create directory layout ───────────────────────────────────────────────────
mkdir -p "${WORK_DIR}" "${OUT_DIR}" "${PACKAGES_DIR}"
mkdir -p "${SCRIPT_DIR}/overlayfs/etc/apt/trusted.gpg.d" \
         "${SCRIPT_DIR}/overlayfs/etc/apt/sources.list.d"

# ── Download official Proxmox VE ISO ─────────────────────────────────────────
ISO_DEST="${WORK_DIR}/${PVE_ISO_NAME}"
if [[ -f "${ISO_DEST}" ]]; then
    log "Proxmox VE ISO already present: ${ISO_DEST}"
    log "  Delete it and re-run prepare.sh to force a fresh download."
else
    log "Downloading Proxmox VE ${PVE_VERSION} ISO..."
    wget -c --show-progress -P "${WORK_DIR}/" "${PVE_ISO_URL}"
fi

# Verify SHA256 against Proxmox's published checksum file
log "Verifying ISO integrity..."
EXPECTED_SHA=$(curl -sL "https://enterprise.proxmox.com/iso/SHA256SUMS" \
    | grep "${PVE_ISO_NAME}" | awk '{print $1}')
if [[ -z "${EXPECTED_SHA}" ]]; then
    log "WARNING: Could not fetch upstream SHA256SUMS — skipping verification."
else
    echo "${EXPECTED_SHA}  ${ISO_DEST}" | sha256sum --check \
        && log "ISO checksum OK." \
        || { log "ERROR: ISO checksum mismatch!"; exit 1; }
fi

# ── Download T2 pve-kernel packages ──────────────────────────────────────────
log "Downloading T2 kernel: ${T2_KERNEL_VERSION}"
for deb in "${T2_KERNEL_DEB}" "${T2_HEADERS_DEB}"; do
    dest="${PACKAGES_DIR}/${deb}"
    if [[ -f "${dest}" ]]; then
        log "  Already present: ${deb}"
    else
        log "  Downloading: ${deb}"
        wget -c --show-progress -P "${PACKAGES_DIR}/" \
            "${T2_KERNEL_RELEASE_URL}/${deb}"
    fi
done

# ── Fetch t2linux APT repository GPG key ─────────────────────────────────────
log "Fetching t2linux APT repository GPG key..."
KEY_DEST="${SCRIPT_DIR}/overlayfs/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg"
curl -sL "${T2_APT_REPO_KEYURL}" | gpg --dearmor > "${KEY_DEST}"
log "  Key saved: ${KEY_DEST}"

# ── Write t2linux APT repo list file ─────────────────────────────────────────
log "Writing t2linux APT source list..."
cat > "${SCRIPT_DIR}/overlayfs/etc/apt/sources.list.d/t2.list" << EOF
${T2_APT_REPO_LIST}
${T2_APPLE_FIRMWARE_LIST}
EOF

# ── Ensure build scripts are executable ──────────────────────────────────────
chmod +x "${SCRIPT_DIR}/build.sh" \
         "${SCRIPT_DIR}/run_in_chroot.sh" \
         "${SCRIPT_DIR}/reset.sh"
chmod +x "${SCRIPT_DIR}/overlayfs/usr/bin/"* 2>/dev/null || true

log ""
log "prepare.sh complete."
log "  ISO   : ${ISO_DEST}"
log "  Kernel: ${PACKAGES_DIR}/${T2_KERNEL_DEB}"
log ""
log "Run: sudo bash build.sh"
