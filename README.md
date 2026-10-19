# Optimized Void Linux kernel for HP Pavilion x360

A device-specific Linux kernel package for **Void Linux x86_64-musl**, built through Void's `xbps-src` packaging system on GitHub Actions.

## Target hardware

- **CPU:** Intel Core i3-6100U (Skylake, 2 cores / 4 threads)
- **Graphics:** Intel HD Graphics 520 (`i915`)
- **Wi-Fi:** Intel Wireless 3165 (`iwlwifi`)
- **Ethernet:** Realtek RTL810xE (`r8169`)
- **Storage:** SATA/AHCI (`ahci`)
- **Audio:** Intel HD Audio (`snd_hda_intel`)
- **Card reader:** Realtek RTS522A (`rtsx_pci`)
- **Platform:** HP Pavilion x360, UEFI

## Kernel source version

- The build targets **Linux 7.3-rc7**, the latest published 7.3 mainline candidate shown by [kernel.org](https://www.kernel.org/) on October 19, 2026. It is a release candidate, not a stable release; kernel.org lists 7.2.11 as the latest stable version at that time.
- Void Packages does not yet maintain a `linux7.3` template. Until it does, the script adapts the newest maintained Void kernel template to package upstream's `linux-7.3-rc7.tar.gz`, with its SHA-256 pinned in the script.
- When Void adds its own `linux7.3` template, the build uses that maintained template rather than creating a local copy.

## Device-specific optimization

- Compile with GCC `-march=skylake -mtune=skylake`; this is deliberately not intended to run on older CPU generations.
- Keep the Intel graphics, Intel Wi-Fi, Realtek Ethernet/card-reader, SATA/AHCI, HD-audio, input and power-management support from Void's maintained configuration.
- Use a 1000 Hz timer with tickless idle, default Intel P-state to the performance governor, size CPU tables for four logical CPUs, and disable NUMA balancing and NUMA support for this single-node laptop.
- Disable selected runtime debug/statistics overhead, embedded DWARF/BTF debug data, and non-target GPU drivers (AMD/ATI, Nouveau, VMware, VirtIO, QXL, and virtual/server display adapters). Kconfig resolves symbols available in each kernel version; target-device drivers are not deliberately removed.
- The performance governor and 1000 Hz tick prioritize responsiveness; power draw, battery life, and thermals may worsen. These are configuration choices, not measured performance claims.

## Build and releases

- Pushes to `main` that modify `.github/workflows/build-kernel.yml` or `scripts/**` trigger a build. Documentation-only changes do not consume build minutes. Manual runs are available from **Actions → Build optimized Void Linux kernel**.
- Successful `main` builds publish installable `.xbps` packages as a GitHub prerelease named `kernel-build-N`. The Actions artifact `void-kernel-x86_64-musl-skylake` is also retained for 14 days.
- Published packages target Void Linux `x86_64-musl`; they are not official Void Linux builds.

## Repository hygiene and validation

- Raw system diagnostic dumps were removed from version control because they are not required to build the package. The privacy gate continues to scan any tracked `.txt` files before a build.
- Build caches contain downloaded source archives and binary repository packages only, not chroots or kernel build trees. XBPS package signatures remain enabled.
- A successful CI build proves compilation and packaging only. Test boot, graphics, Wi-Fi, Ethernet, audio, touchscreen/input, card reader, suspend/resume, idle power, and sustained load on the laptop. Keep a known-working kernel installed for rollback.
