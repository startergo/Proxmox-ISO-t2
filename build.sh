#!/usr/bin/env bash
# build.sh — Main ISO build orchestrator for Proxmox-ISO-t2
#
# Takes the official Proxmox VE ISO and repacks it with T2 Mac hardware support.
# Must be run as root (required for chroot bind mounts).
#
# Usage: sudo bash build.sh
#
# Build stages:
#   1. Extract official Proxmox ISO
#   2. Extract pve-base.squashfs
#   3. Apply overlayfs/ and stage packages
#   4. Chroot into squashfs and run run_in_chroot.sh
#   5. Rebuild pve-base.squashfs
#   6. Replace live ISO boot kernel with T2 kernel
#   7. Update GRUB configuration
#   8. Repack final ISO

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/build.conf"

# ── Sanity checks ─────────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: build.sh must be run as root (sudo bash build.sh)"
    exit 1
fi

ISO_SRC="${WORK_DIR}/${PVE_ISO_NAME}"
SQUASHFS_PATH=""  # set by stage_extract_base_squashfs, used by stage_rebuild_base_squashfs
if [[ ! -f "${ISO_SRC}" ]]; then
    echo "ERROR: Proxmox ISO not found: ${ISO_SRC}"
    echo "       Run ./prepare.sh first."
    exit 1
fi

if [[ ! -f "${PACKAGES_DIR}/${T2_KERNEL_DEB}" ]]; then
    echo "ERROR: T2 kernel package not found: ${PACKAGES_DIR}/${T2_KERNEL_DEB}"
    echo "       Run ./prepare.sh first."
    exit 1
fi

check_deps() {
    local deps=(xorriso unsquashfs mksquashfs chroot mount umount dd sha256sum wget curl)
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "${dep}" &>/dev/null || missing+=("${dep}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required tools: ${missing[*]}"
        echo "       On Debian/Ubuntu: sudo apt install xorriso squashfs-tools"
        exit 1
    fi
}

log() { echo "[build] $*"; }

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    log "Cleaning up mounts..."
    local mounts=(
        "${PVE_BASE_EXTRACT}/dev/pts"
        "${PVE_BASE_EXTRACT}/dev"
        "${PVE_BASE_EXTRACT}/proc"
        "${PVE_BASE_EXTRACT}/sys"
        "${PVE_BASE_EXTRACT}/run"
    )
    for mp in "${mounts[@]}"; do
        if mountpoint -q "${mp}" 2>/dev/null; then
            umount -l "${mp}" || true
        fi
    done
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 1: Extract official Proxmox ISO
# ─────────────────────────────────────────────────────────────────────────────
stage_extract_iso() {
    log "Stage 1: Extracting Proxmox VE ISO..."
    if [[ -d "${ISO_EXTRACT_DIR}" ]]; then
        log "  ISO already extracted — removing stale extract..."
        rm -rf "${ISO_EXTRACT_DIR}"
    fi
    mkdir -p "${ISO_EXTRACT_DIR}"

    # xorriso preserves symlinks and permissions
    xorriso -osirrox on \
            -indev "${ISO_SRC}" \
            -extract / "${ISO_EXTRACT_DIR}" \
            2>/dev/null

    # Make files writable (xorriso extracts as read-only)
    chmod -R u+w "${ISO_EXTRACT_DIR}"

    # Save the original MBR/El Torito boot record for xorriso repack
    dd if="${ISO_SRC}" bs=512 count=1 of="${WORK_DIR}/proxmox.mbr" 2>/dev/null
    log "  ISO extracted to: ${ISO_EXTRACT_DIR}"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 2: Extract pve-base.squashfs
# ─────────────────────────────────────────────────────────────────────────────
stage_extract_base_squashfs() {
    log "Stage 2: Extracting pve-base.squashfs..."
    if [[ -d "${PVE_BASE_EXTRACT}" ]]; then
        rm -rf "${PVE_BASE_EXTRACT}"
    fi

    # Locate the squashfs regardless of ISO directory layout changes
    SQUASHFS_PATH=$(find "${ISO_EXTRACT_DIR}" -name "pve-base.squashfs" -type f | head -1)
    if [[ -z "${SQUASHFS_PATH}" ]]; then
        echo "ERROR: pve-base.squashfs not found anywhere under ${ISO_EXTRACT_DIR}"
        echo "       ISO directory contents:"
        find "${ISO_EXTRACT_DIR}" -maxdepth 3 | sort
        exit 1
    fi
    log "  Found squashfs: ${SQUASHFS_PATH}"

    unsquashfs -d "${PVE_BASE_EXTRACT}" "${SQUASHFS_PATH}"
    log "  Squashfs extracted to: ${PVE_BASE_EXTRACT}"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 3: Apply overlay files and stage packages
# ─────────────────────────────────────────────────────────────────────────────
stage_apply_overlay() {
    log "Stage 3: Applying overlayfs/ onto squashfs..."
    cp -a "${SCRIPT_DIR}/overlayfs/." "${PVE_BASE_EXTRACT}/"

    # Make overlay scripts executable inside the squashfs
    chmod +x "${PVE_BASE_EXTRACT}/usr/bin/t2-hardware-setup" \
             "${PVE_BASE_EXTRACT}/usr/bin/t2-wifi-firmware" \
             "${PVE_BASE_EXTRACT}/usr/bin/t2-first-boot" 2>/dev/null || true

    # Stage T2 kernel .deb packages into /tmp/packages/ inside squashfs
    mkdir -p "${PVE_BASE_EXTRACT}/tmp/packages"
    cp "${PACKAGES_DIR}/"*.deb "${PVE_BASE_EXTRACT}/tmp/packages/" 2>/dev/null || true

    # Copy run_in_chroot.sh into the squashfs for execution
    cp "${SCRIPT_DIR}/run_in_chroot.sh" "${PVE_BASE_EXTRACT}/tmp/run_in_chroot.sh"
    chmod +x "${PVE_BASE_EXTRACT}/tmp/run_in_chroot.sh"

    log "  Overlay applied. Staged $(ls "${PVE_BASE_EXTRACT}/tmp/packages/" | wc -l) package(s)."
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 4: Chroot into squashfs and run run_in_chroot.sh
# ─────────────────────────────────────────────────────────────────────────────
stage_chroot() {
    log "Stage 4: Entering chroot..."

    mount --bind /proc    "${PVE_BASE_EXTRACT}/proc"
    mount --bind /sys     "${PVE_BASE_EXTRACT}/sys"
    mount --bind /dev     "${PVE_BASE_EXTRACT}/dev"
    mount --bind /dev/pts "${PVE_BASE_EXTRACT}/dev/pts"
    mount --bind /run     "${PVE_BASE_EXTRACT}/run"

    # Provide DNS resolution inside chroot
    cp /etc/resolv.conf "${PVE_BASE_EXTRACT}/etc/resolv.conf"

    # Copy host CA certificates so HTTPS apt repos work inside the chroot
    # (ca-certificates cannot be installed via apt in the minimal Proxmox squashfs)
    mkdir -p "${PVE_BASE_EXTRACT}/etc/ssl/certs"
    cp /etc/ssl/certs/ca-certificates.crt "${PVE_BASE_EXTRACT}/etc/ssl/certs/ca-certificates.crt"

    # Run the chroot script
    chroot "${PVE_BASE_EXTRACT}" /bin/bash /tmp/run_in_chroot.sh

    # Remove resolv.conf — will be regenerated at runtime
    rm -f "${PVE_BASE_EXTRACT}/etc/resolv.conf"

    # Unmount bind mounts — must happen before mksquashfs in Stage 5
    for mp in "${PVE_BASE_EXTRACT}/dev/pts" \
              "${PVE_BASE_EXTRACT}/dev" \
              "${PVE_BASE_EXTRACT}/proc" \
              "${PVE_BASE_EXTRACT}/sys" \
              "${PVE_BASE_EXTRACT}/run"; do
        mountpoint -q "${mp}" && umount -l "${mp}" || true
    done
    log "  Chroot complete."
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 5: Rebuild pve-base.squashfs
# ─────────────────────────────────────────────────────────────────────────────
stage_rebuild_base_squashfs() {
    log "Stage 5: Rebuilding pve-base.squashfs (zstd compression)..."
    rm -f "${SQUASHFS_PATH}"
    mksquashfs "${PVE_BASE_EXTRACT}" \
               "${SQUASHFS_PATH}" \
               -comp zstd -Xcompression-level 15 \
               -b 1M -no-progress -noappend \
               -e "${PVE_BASE_EXTRACT}/proc" \
               -e "${PVE_BASE_EXTRACT}/sys" \
               -e "${PVE_BASE_EXTRACT}/dev" \
               -e "${PVE_BASE_EXTRACT}/run"
    log "  pve-base.squashfs rebuilt."
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 6: Replace live ISO boot kernel with T2 kernel
# ─────────────────────────────────────────────────────────────────────────────
stage_replace_boot_kernel() {
    log "Stage 6: Replacing live ISO boot kernel with T2 kernel..."

    # Find the T2 kernel and initrd installed into the squashfs
    local t2_vmlinuz
    t2_vmlinuz=$(find "${PVE_BASE_EXTRACT}/boot" -maxdepth 1 \
        -name "vmlinuz-*t2*" | sort -V | tail -1)

    local t2_initrd
    t2_initrd=$(find "${PVE_BASE_EXTRACT}/boot" -maxdepth 1 \
        -name "initrd.img-*t2*" | sort -V | tail -1)

    if [[ -z "${t2_vmlinuz}" || -z "${t2_initrd}" ]]; then
        echo "ERROR: T2 kernel or initrd not found in ${PVE_BASE_EXTRACT}/boot/"
        echo "       The T2 kernel may have failed to install. Check run_in_chroot.sh output."
        exit 1
    fi

    log "  Kernel : $(basename "${t2_vmlinuz}")"
    log "  Initrd : $(basename "${t2_initrd}")"

    # The Proxmox live ISO boots from /boot/linux26 and /boot/initrd.img
    cp "${t2_vmlinuz}" "${ISO_EXTRACT_DIR}/boot/linux26"
    cp "${t2_initrd}"  "${ISO_EXTRACT_DIR}/boot/initrd.img"
    log "  Boot kernel replaced."
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 7: Update GRUB configuration
# ─────────────────────────────────────────────────────────────────────────────
stage_update_grub() {
    log "Stage 7: Updating GRUB configuration..."
    local grub_src="${SCRIPT_DIR}/boot/grub/grub.cfg"

    if [[ ! -f "${grub_src}" ]]; then
        echo "ERROR: boot/grub/grub.cfg not found in repo."
        exit 1
    fi

    # Update both BIOS and EFI GRUB config locations
    cp "${grub_src}" "${ISO_EXTRACT_DIR}/boot/grub/grub.cfg"

    # EFI grub.cfg location varies; copy to both common locations
    if [[ -d "${ISO_EXTRACT_DIR}/EFI/BOOT" ]]; then
        cp "${grub_src}" "${ISO_EXTRACT_DIR}/EFI/BOOT/grub.cfg"
    fi
    if [[ -d "${ISO_EXTRACT_DIR}/boot/grub/x86_64-efi" ]]; then
        cp "${grub_src}" "${ISO_EXTRACT_DIR}/boot/grub/x86_64-efi/grub.cfg"
    fi

    log "  GRUB config updated."
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 8: Repack ISO
# ─────────────────────────────────────────────────────────────────────────────
stage_repack_iso() {
    log "Stage 8: Repacking ISO..."
    mkdir -p "${OUT_DIR}"
    local mod_date
    mod_date=$(date +%Y%m%d%H%M%S00)

    xorriso -as mkisofs \
        -o "${ISO_OUT}" \
        -r -V "${ISO_LABEL}" \
        --modification-date="${mod_date}" \
        --grub2-mbr "${WORK_DIR}/proxmox.mbr" \
        --protective-msdos-label \
        -efi-boot-part --efi-boot-image \
        -c '/boot/boot.cat' \
        -b '/boot/grub/i386-pc/eltorito.img' \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e '/boot/grub/efi.img' \
        -no-emul-boot \
        "${ISO_EXTRACT_DIR}"

    log "  ISO written: ${ISO_OUT}"
    sha256sum "${ISO_OUT}" | tee "${ISO_OUT}.sha256"
    log "  SHA256: ${ISO_OUT}.sha256"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
check_deps

log "========================================"
log " Proxmox-ISO-t2 Build"
log " PVE ${PVE_VERSION}  |  T2 kernel ${T2_KERNEL_VERSION}"
log "========================================"

stage_extract_iso
stage_extract_base_squashfs
stage_apply_overlay
stage_chroot
stage_rebuild_base_squashfs
stage_replace_boot_kernel
stage_update_grub
stage_repack_iso

log ""
log "========================================"
log " Build complete!"
log " Output: ${ISO_OUT}"
log "========================================"
