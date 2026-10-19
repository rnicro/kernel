# Optimized Void Linux kernel for HP Pavilion x360

A device-specific Linux kernel package for **Void Linux x86_64-musl**, built with Void's `xbps-src` on GitHub Actions.

## Target hardware

- **CPU:** Intel Core i3-6100U (Skylake, 2 cores / 4 threads)
- **Graphics:** Intel HD Graphics 520 (`i915`), retained for Wayland/dwl DRM/KMS
- **Wi-Fi:** Intel Wireless 3165 (`iwlwifi`)
- **Ethernet:** Realtek RTL810xE (`r8169`)
- **Storage:** SATA/AHCI (`ahci`)
- **Audio:** Intel HD Audio (`snd_hda_intel`); ALSA remains enabled for PipeWire/WirePlumber
- **Card reader:** Realtek RTS522A (Realtek PCIe card-reader drivers)
- **Platform:** HP Pavilion x360, UEFI

## Kernel and device profile

- Targets **Linux 7.3 mainline**. As of 2026-10-19, 7.3 is mainline rather than stable; kernel.org lists 7.2.11 as the latest stable release. This repository intentionally follows 7.3 as requested.
- Compile with `-march=skylake -mtune=skylake`; this device-specific kernel is not intended for older CPUs.
- Keep ext4, FAT/VFAT, swap, ISO9660 and SquashFS. Ext4 is built in for root-filesystem robustness; FAT/VFAT remain modules for EFI/removable-media support. ISO9660 and SquashFS remain available for OS installer/live media.
- Disable unused filesystems and network mounts, including Btrfs, XFS, F2FS, JFS, NILFS2, NTFS, exFAT, UDF, HFS, NFS, CIFS/SMB and other less-common filesystems. This profile will not mount exFAT or NTFS drives unless those options are re-enabled.
- Disable touchscreen, webcam/video-capture and legacy OSS audio emulation. General keyboard, mouse/touchpad, USB storage, graphics, ALSA audio and laptop power management remain enabled.
- Disable FUSE, OverlayFS, virtualization/guest drivers and Intel GVT, matching the current no-AppImage/no-container/no-VM usage. FUSE-based tools such as SSHFS also require FUSE to be re-enabled.
- dwl and the absence of X11/Xwayland are userspace choices; there is no kernel option specifically for Xwayland. i915 DRM/KMS stays enabled for Wayland. PipeWire/WirePlumber use ALSA kernel audio drivers; PulseAudio is not a kernel driver, so legacy OSS emulation is what is removed.
- Keep a 1000 Hz scheduler tick with tickless idle, the Intel P-state performance governor default, CPU tables sized for four logical CPUs, and NUMA support/balancing disabled.
- A post-`oldconfig` audit fails the build if required target drivers/filesystems are missing or excluded filesystems, webcam/touchscreen, OSS compatibility or virtualization options unexpectedly remain enabled.
- These settings aim to reduce modules and package/build overhead. The performance governor and 1000 Hz timing may increase heat and power consumption; verify results on the actual laptop.

## Build and releases

- Pushes to `main` changing `.github/workflows/build-kernel.yml` or `scripts/**` trigger a build. Manual runs are available in **Actions → Build optimized Void Linux kernel**.
- Uses Void’s maintained `linux7.3` template when available. Until then, the build derives a local template from `linux7.2`, fetches the official Linux 7.3 archive, verifies its detached PGP signature against Greg Kroah-Hartman’s pinned fingerprint, and derives the XBPS checksum only after verification.
- GitHub Release titles and tags use `kernel-<version>_<revision>` (for example, `kernel-7.3_1`). The release body is empty; assets are limited to the installable kernel and matching headers packages, with debug packages and sidecars excluded. The Actions artifact `kernel-x86_64-musl` is retained for one day.
- Packages target Void Linux `x86_64-musl`; these are custom builds, not official Void Linux packages.

## Check that the installed kernel works

After installing the package and rebooting into it, run:

```sh
uname -r
xbps-query -l | grep -E '^ii linux[0-9]'
lspci -k
sudo dmesg -l err,warn
```

Confirm `uname -r` matches the installed kernel. Check `lspci -k` for expected drivers (`i915`, `iwlwifi`, `r8169`, `ahci`, `snd_hda_intel`) and test USB storage, Wi-Fi, Ethernet, audio, brightness, touchpad, card reader and suspend/resume. Keep a known-working kernel installed for rollback. A successful CI build does not prove hardware compatibility.

## Repository hygiene

- Raw hardware diagnostic dumps are not tracked; the privacy scanner stays as a guard for any future `.txt` files.
- Actions caches contain source archives and binary repository packages only, not build trees or chroots. XBPS package signature verification remains enabled.
