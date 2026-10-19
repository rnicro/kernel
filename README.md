# Optimized Void Linux kernel for HP Pavilion x360

A device-specific kernel package for **Void Linux x86_64-musl**, compiled on GitHub Actions using Void's `xbps-src` packaging system.

## Target hardware

- **CPU:** Intel Core i3-6100U (Skylake, 2 cores / 4 threads)
- **Graphics:** Intel HD Graphics 520 (`i915`)
- **Wi-Fi:** Intel Wireless 3165 (`iwlwifi`)
- **Ethernet:** Realtek RTL810xE (`r8169`)
- **Storage:** SATA/AHCI (`ahci`)
- **Audio:** Intel HD Audio (`snd_hda_intel`)
- **Card reader:** Realtek RTS522A (`rtsx_pci`)
- **Platform:** HP Pavilion x360, UEFI

## Kernel and performance

- Automatically selects the newest stable numeric kernel version with a maintained template in Void Packages; pre-release versions are excluded. As of October 19, 2026, this selects Linux **7.2.11** (`linux7.2`). See [kernel.org](https://www.kernel.org/) for the current upstream stable release.
- Compiles with `-march=skylake -mtune=skylake`; this personal build is not intended for older CPUs.
- Keeps support for the target Intel graphics/Wi-Fi, Realtek Ethernet/card reader, AHCI, audio, input, and laptop power management.
- Uses a 1000 Hz tick with tickless idle, defaults Intel P-state to the performance governor, sizes CPU tables for four logical CPUs, and disables NUMA support/balancing for the single-node target.
- Disables selected runtime debug/statistics overhead, DWARF/BTF debug data, and non-target GPU drivers (AMD/ATI, Nouveau, VMware, VirtIO, QXL, and virtual/server display adapters). Other hardware drivers are retained when their absence cannot be established safely.
- These choices favor interactive responsiveness and smaller/faster builds; the performance governor can increase heat and battery use. No performance gain is claimed without on-device testing.

## Build and releases

- Pushes to `main` that modify `.github/workflows/build-kernel.yml` or `scripts/**` trigger a build. Manual runs are available in **Actions → Build optimized Void Linux kernel**.
- Successful `main` builds publish installable `.xbps` packages to a GitHub Release named for the built kernel version. The Actions artifact `void-kernel-x86_64-musl-skylake` is also retained for 14 days.
- Packages target Void Linux `x86_64-musl`; they are custom builds, not official Void Linux packages.

## Check that the installed kernel works

After installing the package and rebooting into it, run:

```sh
uname -r
xbps-query -l | grep -E '^ii linux[0-9]'
lspci -k
sudo dmesg -l err,warn
```

Confirm `uname -r` matches the new kernel, `lspci -k` shows expected drivers for present devices (`i915`, `iwlwifi`, `r8169`, `ahci`, `snd_hda_intel`, `rtsx_pci`), and logs contain no new repeated failures. Test Wi-Fi, Ethernet, sound, brightness, touch input, card reader, and suspend/resume. Keep a known-working kernel installed for rollback; a successful CI build alone does not prove hardware compatibility.

## Repository hygiene

- Raw system diagnostic dumps were removed because they are not build inputs. The privacy scan remains as a guard for future tracked `.txt` files.
- Actions caches contain downloaded source archives and repository packages only, not build trees or chroots. XBPS package signature verification remains enabled.
