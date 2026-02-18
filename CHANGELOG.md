# Changelog

## [Unreleased] — senpai branch

### Added
- Initial repository structure based on EndeavourOS-ISO-t2 pattern
- `build.conf` — central version/URL configuration
- `prepare.sh` — download official Proxmox VE ISO + T2 kernel packages
- `build.sh` — 8-stage ISO repack orchestrator
- `run_in_chroot.sh` — installs T2 packages inside pve-base.squashfs
- `reset.sh` — clean build artefacts
- `overlayfs/etc/systemd/system/apple-bce-load.service` — early module loading
- `overlayfs/etc/systemd/system/t2-hardware-setup.service` — hardware detection
- `overlayfs/etc/systemd/system/t2-first-boot.service` — post-install kernel setup
- `overlayfs/usr/bin/t2-hardware-setup` — T2 hardware detection script
- `overlayfs/usr/bin/t2-wifi-firmware` — WiFi firmware installation guide
- `overlayfs/usr/bin/t2-first-boot` — post-install T2 kernel configurator
- `overlayfs/etc/modprobe.d/apple-bce.conf` — module soft dependency ordering
- `overlayfs/etc/modules-load.d/apple-bce.conf` — early module loading
- `overlayfs/etc/logind.conf.d/do-not-suspend.conf` — prevent MacBook lid suspend
- `boot/grub/grub.cfg` — GRUB config with T2 kernel parameters
- `.github/workflows/build.yml` — GitHub Actions CI with ISO caching and release publishing
- T2 kernel: `pve-edge-kernel-t2` (Proxmox-native kernel format)
- T2 packages: `apple-t2-audio-config`, `firmware-brcm80211`, `apple-firmware-script`, `tiny-dfr`
