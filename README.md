# Proxmox-ISO-t2

[![Build](https://github.com/startergo/Proxmox-ISO-t2/actions/workflows/build.yml/badge.svg)](https://github.com/startergo/Proxmox-ISO-t2/actions/workflows/build.yml)

Repackages the official **Proxmox VE ISO** with T2 Mac hardware support, producing a
bootable installer that works on Apple T2-based Macs out of the box.

Modelled after [EndeavourOS-ISO-t2](https://github.com/endeavouros-team/EndeavourOS-ISO-t2).

---

## What this adds to the official Proxmox VE ISO

| Component | Source |
|---|---|
| T2-patched Proxmox kernel (`proxmox-kernel-*-pve-t2`) | [AdityaGarg8/pve-edge-kernel-t2](https://github.com/AdityaGarg8/pve-edge-kernel-t2) |
| `apple-firmware` (WiFi/BT firmware) | [AdityaGarg8/Apple-Firmware](https://github.com/AdityaGarg8/Apple-Firmware) APT repo |
| `tiny-dfr-adv` (Touch Bar) | [AdityaGarg8/t2-ubuntu-repo](https://github.com/AdityaGarg8/t2-ubuntu-repo) APT repo |
| T2 kernel parameters in GRUB | `intel_iommu=on iommu=pt pcie_ports=compat` |
| Hardware detection service | `t2-hardware-setup.service` |
| First-boot kernel setup | `t2-first-boot.service` |

**WiFi/Bluetooth firmware is incorporated** into the ISO via the `apple-firmware` package (firmware extracted from macOS, sourced from [AdityaGarg8/Apple-Firmware](https://github.com/AdityaGarg8/Apple-Firmware)).

---

## Supported hardware

- MacBook Pro 2018–2020 (T2)
- MacBook Air 2018–2020 (T2)
- Mac mini 2018 (T2)
- Mac Pro 2019 (T2)
- iMac 2019 (T2)
- iMac Pro 2017 (T2)

---

## Build requirements

A Debian or Ubuntu build machine (or GitHub Actions). The following packages are needed:

```
xorriso squashfs-tools mtools curl wget gpg dosfstools grub-pc-bin grub-efi-amd64-bin
```

On Debian/Ubuntu:
```bash
sudo apt install xorriso squashfs-tools mtools curl wget gpg dosfstools \
    grub-pc-bin grub-efi-amd64-bin
```

Root is required for `build.sh` (chroot bind mounts and squashfs operations).

---

## Quick start

```bash
git clone https://github.com/your-org/Proxmox-ISO-t2
cd Proxmox-ISO-t2

# Download official Proxmox ISO and T2 kernel packages
bash prepare.sh

# Build the T2 ISO (requires root)
sudo bash build.sh
```

Output: `out/proxmox-ve-t2_VERSION.iso`

---

## Build workflow

| Step | Script | Description |
|---|---|---|
| 1 | `prepare.sh` | Downloads official Proxmox VE ISO + T2 kernel `.deb` packages |
| 2 | `build.sh` | 8-stage ISO repack (extract → chroot → squash → repack) |
| — | `run_in_chroot.sh` | Called by build.sh; installs packages inside the squashfs |
| — | `reset.sh` | Removes build artefacts for a fresh rebuild |

### Build stages (build.sh)

1. Extract official Proxmox ISO with `xorriso`
2. Extract `pve-base.squashfs` with `unsquashfs`
3. Apply `overlayfs/` onto squashfs root; stage `.deb` packages
4. `chroot` into squashfs → run `run_in_chroot.sh`
5. Rebuild `pve-base.squashfs` with `mksquashfs -comp zstd`
6. Replace live ISO `/boot/linux26` + `initrd.img` with T2 kernel/initrd
7. Update GRUB configuration
8. Repack ISO with `xorriso -as mkisofs`

---

## Post-installation (automatic)

After Proxmox is installed to disk, `t2-first-boot.service` runs automatically on
first boot. It:

1. Adds t2linux APT repository
2. Installs the T2 kernel on the installed system
3. Configures GRUB with T2 kernel parameters
4. Updates initramfs with `apple-bce` and `apple-ibridge`
5. Pins the T2 kernel via `proxmox-boot-tool`
6. Creates `/etc/t2-first-boot-done` sentinel, then reboots

The service only runs once. Check `/var/log/t2-first-boot.log` for details.

---

## WiFi

T2 Mac WiFi and Bluetooth firmware is incorporated into the ISO via the
`apple-firmware` package — firmware files extracted from macOS, provided by
[AdityaGarg8/Apple-Firmware](https://github.com/AdityaGarg8/Apple-Firmware).
No manual firmware installation is required.

See also: [wiki.t2linux.org/guides/wifi-bluetooth](https://wiki.t2linux.org/guides/wifi-bluetooth/)

---

## Repository structure

```
Proxmox-ISO-t2/
├── build.conf                  # Central version/URL variables
├── prepare.sh                  # Download phase (ISO + .deb packages)
├── build.sh                    # Main ISO repack orchestrator
├── run_in_chroot.sh            # Runs inside squashfs chroot
├── reset.sh                    # Clean build artefacts
├── packages.list               # T2 package additions (reference)
│
├── overlayfs/                  # Files injected into pve-base.squashfs
│   ├── etc/
│   │   ├── apt/sources.list.d/t2.list
│   │   ├── modprobe.d/apple-bce.conf
│   │   ├── modules-load.d/apple-bce.conf
│   │   ├── logind.conf.d/do-not-suspend.conf
│   │   ├── motd
│   │   └── systemd/system/
│   │       ├── apple-bce-load.service
│   │       ├── t2-hardware-setup.service
│   │       └── t2-first-boot.service
│   └── usr/bin/
│       ├── t2-hardware-setup
│       ├── t2-wifi-firmware
│       └── t2-first-boot
│
├── boot/grub/grub.cfg          # GRUB config with T2 kernel parameters
│
└── .github/workflows/build.yml # GitHub Actions CI/CD
```

---

## Credits

- [pve-edge-kernel-t2](https://github.com/AdityaGarg8/pve-edge-kernel-t2) — T2 kernel for Proxmox VE
- [t2-ubuntu-repo](https://github.com/AdityaGarg8/t2-ubuntu-repo) — APT repo for T2 packages
- [t2linux](https://wiki.t2linux.org) — T2 Linux project, wiki, and community
- [EndeavourOS-ISO-t2](https://github.com/endeavouros-team/EndeavourOS-ISO-t2) — Structural inspiration
