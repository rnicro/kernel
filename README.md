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
- Compiles kernel C code with GCC `-march=skylake -mtune=skylake`, targeting the Intel Core i3-6100U rather than the GitHub runner. **This is CPU-specific:** do not install this package on older x86 CPUs or redistribute it as a generic x86-64 kernel.
- Creates a target-specific `x86_64-dotconfig-custom` overlay from Void's maintained config. It changes the periodic tick from 1000 Hz to 300 Hz to balance interactive responsiveness with laptop interrupt/idle overhead; Kconfig's `oldconfig` resolves symbols unsupported by the selected kernel series.
- Retains Void's broad driver configuration for graphics, wireless, storage, audio, card reader, input, power management, and external modules. It does not disable device drivers or enable experimental features merely to reduce the configuration size.
- Builds inside the official Void musl container and publishes x86_64-musl packages. GitHub Actions grants the container the namespace support required by `xbps-src` chroots.
- Caches Void binary repository downloads and upstream source archives in GitHub Actions. Cache keys rotate weekly and reuse prior-week downloads; caches are saved only after a successful build to avoid filling the repository cache quota with repeated failed-run snapshots. Only downloaded inputs are cached, not host-specific chroots or kernel build trees.
- Uses HTTPS and XBPS package-signature verification. The build overrides the failing default mirror endpoint with `repo-de.voidlinux.org` and retries transient repository failures.
- The artifact contains installable kernel and headers `.xbps` packages only; debug packages and build metadata are excluded.

## Build

1. Open **Actions → Build optimized Void Linux kernel**.
2. Run the workflow on `main`; it detects the newest kernel series available in Void Packages automatically.
3. Download the `void-kernel-x86_64-musl-skylake` artifact after a successful run.

Pushes to `main` that modify the workflow or build scripts trigger a build; documentation-only edits do not consume build minutes. Use **workflow_dispatch** to rebuild against the newest kernel template currently available in Void Packages. All routine changes go directly to `main`; do not create feature branches.

## Validation and safety

- GitHub Actions performs compilation; the target laptop is not used as a build machine. The workflow caches reusable downloads to reduce repeat build setup time.
- The build uses Void's `xbps-src` packaging template. It bootstraps and compiles as a dedicated unprivileged `builder` account (required by `xbps-src`) using `uunshare` for both phases, so the target master directory remains isolated. The container's inherited `ethereal` mode is explicitly overridden because it requires the master directory to be a symlink to `/`.
- The Skylake-specific compiler target can emit instructions unavailable on older CPUs; only use the package on the intended i3-6100U/Skylake laptop. A successful build does not prove bootability or improved performance, battery life, or thermals. Test boot, suspend/resume, Wi-Fi, graphics, audio, touch input, card reader, idle power, and sustained load.
- A 300 Hz tick may trade some peak latency behavior for lower periodic-tick overhead compared with 1000 Hz; benchmark the actual workload and revert the overlay if responsiveness regresses.
- Keep a known-working kernel installed for rollback. This is a personal custom package, not an official Void Linux build.
