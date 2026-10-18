# Optimized Void Linux kernel for HP Pavilion x360

Builds the newest stable Linux kernel series available as a maintained template in Void Packages, producing installable packages for Void Linux x86_64-musl. Compilation runs on GitHub-hosted runners, not on the laptop.

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

- Automatically selects the highest versioned `linuxX.Y` kernel template available in the current Void Packages checkout. This follows new stable series when Void adds their package template; it does not build release candidates merely because they exist upstream.
- Uses Void's maintained kernel template and x86_64 configuration rather than a hand-rolled kernel package.
- Adds GCC's `-mtune=skylake` scheduling hint without raising the x86-64 instruction-set baseline. It deliberately avoids `-march=native`, which would tune for the GitHub runner and could emit unsupported instructions.
- Preserves Void's broad driver configuration for graphics, wireless, storage, audio, card reader, input, power management, and external modules. Hardware-driver pruning and speculative Kconfig changes are avoided unless measurements and device tests justify them.
- Builds inside the official Void musl container and publishes x86_64-musl packages. GitHub Actions grants the container the namespace support required by `xbps-src` chroots.
- Caches Void binary repository downloads and upstream source archives in GitHub Actions. Cache keys rotate weekly, with restore prefixes to reuse prior weeks; only downloaded inputs are cached, not host-specific chroots or kernel build trees.
- Uses HTTPS and XBPS package-signature verification. The build overrides the failing default mirror endpoint with `repo-de.voidlinux.org` and retries transient repository failures.
- The artifact contains installable kernel and headers `.xbps` packages only; debug packages and build metadata are excluded.

## Build

1. Open **Actions → Build optimized Void Linux kernel**.
2. Run the workflow on `main`; it detects the newest kernel series available in Void Packages automatically.
3. Download the `void-kernel-x86_64-musl-skylake` artifact after a successful run.

Pushes to `main` that modify the workflow, build scripts, or README trigger a build. All routine changes go directly to `main`; do not create feature branches.

## Validation and safety

- GitHub Actions performs compilation; the target laptop is not used as a build machine. The workflow caches reusable downloads to reduce repeat build setup time.
- The build uses Void's `xbps-src` packaging template. It bootstraps and compiles as a dedicated unprivileged `builder` account (required by `xbps-src`), enabling the hosted-runner-compatible ethereal chroot only after bootstrap.
- A successful package build does not prove that the kernel boots or improves real-world performance. Test installation, boot, suspend/resume, Wi-Fi, graphics, audio, touch input, card reader, and power behavior before relying on it.
- Keep a known-working kernel installed for rollback. This is a personal custom package, not an official Void Linux build.
