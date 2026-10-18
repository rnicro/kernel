# Optimized Void Linux kernel for HP Pavilion x360

Builds the **Linux 7.2 stable series** as installable Void Linux packages for the target HP Pavilion x360. Builds run on GitHub-hosted runners, not on the laptop.

## Target hardware

- **CPU:** Intel Core i3-6100U (Skylake, 2 cores / 4 threads)
- **Graphics:** Intel HD Graphics 520 (i915)
- **Wi-Fi:** Intel Wireless 3165 (iwlwifi)
- **Ethernet:** Realtek RTL810xE (r8169)
- **Storage:** Intel Sunrise Point-LP SATA/AHCI (ahci)
- **Audio:** Intel Sunrise Point-LP HD Audio (snd_hda_intel)
- **Card reader:** Realtek RTS522A (rtsx_pci)
- **Platform:** HP Pavilion x360, UEFI

## Kernel and device tuning

- Uses Void's maintained `linux7.2` template and x86_64 kernel configuration. The upstream Void template determines the current 7.2.y stable patch version (currently 7.2.11).
- Adds GCC's `-mtune=skylake` scheduling hint without raising the x86-64 instruction-set baseline. It deliberately avoids `-march=native`, which would tune for the GitHub runner and could emit unsupported instructions.
- Preserves Void's broad driver configuration for graphics, wireless, storage, audio, card reader, input, power management, and external modules. Disabling hardware drivers or using speculative Kconfig changes can make the laptop less usable without delivering a measurable performance gain.
- Builds inside the official Void musl container and publishes x86_64-musl packages.
- Uses HTTPS and XBPS package-signature verification. The build overrides the failing default mirror endpoint with the official `repo-de.voidlinux.org` mirror and retries transient repository failures.
- The build artifact contains installable `.xbps` kernel and headers packages only; debug packages and build metadata are excluded.

## Build

1. Open **Actions → Build optimized Void Linux kernel**.
2. Run the workflow on `main`; `linux7.2` is the only supported workflow choice.
3. Download `void-kernel-x86_64-musl-skylake` after a successful run.

Pushes to `main` that modify the workflow, build scripts, or README trigger a build. All routine changes go directly to `main`; do not create feature branches.

## Validation and safety

- GitHub Actions performs compilation; the target laptop is not used as a build machine.
- The build uses Void's xbps-src packaging template instead of a hand-rolled kernel installation.
- A successful package build does not prove that the kernel boots or improves real-world performance. Test installation, boot, suspend/resume, Wi-Fi, graphics, audio, touch input, card reader, and power behavior before relying on it.
- Keep a known-working kernel installed for rollback. This is a personal custom package, not an official Void Linux build.
