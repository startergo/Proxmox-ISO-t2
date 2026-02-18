#!/usr/bin/env bash
# run_in_chroot.sh — Runs inside pve-base.squashfs chroot
# Called by build.sh stage 4. Installs the T2 kernel, hardware support
# packages, and configures the system for T2 Mac hardware.
#
# WiFi: firmware-brcm80211 from Debian non-free-firmware provides the
# Broadcom WiFi firmware. No DKMS build required.
#
# Do NOT run this directly — it is copied into the squashfs by build.sh.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { echo "[chroot] $*"; }

log "##############################"
log "# start chrooted commandlist #"
log "##############################"

# ── 1. Configure apt sources ──────────────────────────────────────────────────
log "---> 1. Configuring apt sources..."

# Add Debian non-free-firmware for firmware-brcm80211
# Keep the existing Proxmox and Debian repos intact; just ensure non-free-firmware is present.
if grep -qE "^deb .* bookworm " /etc/apt/sources.list 2>/dev/null; then
    # Patch existing bookworm line to include non-free-firmware if not already present
    if ! grep -q "non-free-firmware" /etc/apt/sources.list; then
        sed -i '/^deb .* bookworm / s/$/ non-free non-free-firmware/' /etc/apt/sources.list
    fi
else
    # No existing bookworm line — add Debian mirrors
    cat >> /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
fi

# Disable Proxmox enterprise/ceph repos — they require a subscription and
# return 401 in CI; we only need Debian + t2linux repos for the build.
for f in /etc/apt/sources.list.d/pve-enterprise.list \
          /etc/apt/sources.list.d/ceph.list; do
    [[ -f "${f}" ]] && sed -i 's/^deb /# deb /' "${f}" || true
done

# t2.list was placed by overlayfs/ (key was also placed by overlayfs/)
# CA certs were copied from the host by build.sh so HTTPS repos work.
apt-get update -q

# ── 2. Install T2 pve-kernel from staged .deb packages ───────────────────────
log "---> 2. Installing T2 pve-kernel packages..."
if ls /tmp/packages/proxmox-kernel-*pve-t2*_amd64.deb 1>/dev/null 2>&1; then
    dpkg -i /tmp/packages/proxmox-kernel-*pve-t2*_amd64.deb || apt-get install -f -y
else
    log "ERROR: T2 kernel .deb not found in /tmp/packages/"
    exit 1
fi

if ls /tmp/packages/proxmox-headers-*pve-t2*_amd64.deb 1>/dev/null 2>&1; then
    dpkg -i /tmp/packages/proxmox-headers-*pve-t2*_amd64.deb || apt-get install -f -y
else
    log "  (proxmox-headers not found — skipping)"
fi

# ── 3. Install T2 hardware support packages ───────────────────────────────────
log "---> 3. Installing T2 hardware support packages..."

# The Proxmox squashfs is already merged-usr but lacks this marker package,
# which blocks init-system-helpers and packages that depend on it.
apt-get install -y --no-install-recommends usr-is-merged \
    || log "WARNING: usr-is-merged unavailable — subsequent installs may fail"

# tiny-dfr-adv: Touch Bar daemon (bookworm t2linux repo provides tiny-dfr-adv)
apt-get install -y tiny-dfr-adv 2>/dev/null \
    && log "  tiny-dfr-adv installed (Touch Bar support)" \
    || log "  tiny-dfr-adv not available — skipping"

# ── 3b. Install Apple WiFi/Bluetooth firmware ─────────────────────────────────
log "---> 3b. Installing apple-firmware (WiFi/Bluetooth firmware from macOS)..."
apt-get install -y apple-firmware \
    || log "WARNING: apple-firmware unavailable"

# ── 4. Configure initramfs for T2 modules ────────────────────────────────────
log "---> 4. Configuring initramfs to include T2 modules..."
# apple-bce must be in the initramfs so keyboard/trackpad work before root mount
if ! grep -q "^apple-bce" /etc/initramfs-tools/modules 2>/dev/null; then
    echo "apple-bce"    >> /etc/initramfs-tools/modules
fi
if ! grep -q "^apple-ibridge" /etc/initramfs-tools/modules 2>/dev/null; then
    echo "apple-ibridge" >> /etc/initramfs-tools/modules
fi

# Rebuild initramfs for the T2 kernel
T2_KVER=$(ls /lib/modules/ | grep -i t2 | sort -V | tail -1)
if [[ -n "${T2_KVER}" ]]; then
    log "  Regenerating initramfs for kernel: ${T2_KVER}"
    update-initramfs -u -k "${T2_KVER}"
else
    log "WARNING: No T2 kernel found in /lib/modules/ — initramfs not updated"
fi

# ── 5. Configure GRUB kernel parameters ──────────────────────────────────────
log "---> 5. Configuring GRUB kernel parameters for T2 hardware..."
# These parameters are required for T2 PCIe enumeration (NVMe, WiFi):
#   intel_iommu=on  — enable VT-d IOMMU (required for T2 PCIe devices)
#   iommu=pt        — passthrough mode, reduces IOMMU overhead
#   pcie_ports=compat — required for Apple T2 PCIe port enumeration
if [[ -f /etc/default/grub ]]; then
    sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt pcie_ports=compat"|' \
        /etc/default/grub
    sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet"|' \
        /etc/default/grub
fi

# ── 6. Enable T2 systemd services ────────────────────────────────────────────
log "---> 6. Enabling T2 systemd services..."
systemctl enable apple-bce-load.service   2>/dev/null || true
systemctl enable t2-hardware-setup.service 2>/dev/null || true
systemctl enable t2-first-boot.service    2>/dev/null || true

# ── 7. Stage offline packages for post-install use ───────────────────────────
log "---> 7. Staging packages for post-install use..."
mkdir -p /usr/share/proxmox-t2/packages/
cp /tmp/packages/*.deb /usr/share/proxmox-t2/packages/ 2>/dev/null || true
log "  Staged $(ls /usr/share/proxmox-t2/packages/ | wc -l) package(s) to /usr/share/proxmox-t2/packages/"

# ── 8. Create package versions file ──────────────────────────────────────────
log "---> 8. Creating package versions reference..."
{
    dpkg -l 'proxmox-kernel-*pve-t2*' 2>/dev/null | grep '^ii' | awk '{print $2, $3}' || true
    dpkg -l 'apple-firmware' 2>/dev/null | grep '^ii' | awk '{print $2, $3}' || true
    dpkg -l 'tiny-dfr-adv' 2>/dev/null | grep '^ii' | awk '{print $2, $3}' || true
} > /usr/share/proxmox-t2/package-versions.txt 2>/dev/null || true

# ── 9. Clean up ───────────────────────────────────────────────────────────────
log "---> 9. Cleaning up..."
apt-get clean
rm -rf /tmp/packages/
rm -f /tmp/run_in_chroot.sh

log "############################"
log "# end chrooted commandlist #"
log "############################"
