# Optimized Void Linux kernel for HP Pavilion x360

Builds a Void Linux kernel package on GitHub Actions for this device profile.

## Target hardware

- **CPU:** Intel Core i3-6100U (Skylake, 2 cores / 4 threads)
- **Graphics:** Intel HD Graphics 520 (i915)
- **Wi-Fi:** Intel Wireless 3165 (iwlwifi)
- **Ethernet:** Realtek RTL810xE (r8169)
- **Storage:** Intel Sunrise Point-LP SATA/AHCI (ahci)
- **Audio:** Intel Sunrise Point-LP HD Audio (snd_hda_intel)
- **Card reader:** Realtek RTS522A (rtsx_pci)
- **Platform:** HP Pavilion x360, UEFI

The build starts from Void's maintained x86_64 kernel configuration to preserve broad hardware support, then adds GCC's safe -mtune=skylake scheduling hint. This does not raise the required CPU instruction-set baseline or optimize for the GitHub runner. It does **not** aggressively disable drivers: reducing kernel size does not guarantee improved runtime performance.

## Build

1. Open **Actions → Build optimized Void Linux kernel**.
2. Select **Run workflow** on main, keeping the default linux6.18 package.
3. Download the void-kernel-x86_64-skylake artifact after a successful run.

Pushes to main that modify the workflow, config, scripts, or README also trigger a build. All routine changes go directly to main; this repository does not use feature branches.

## Implementation notes

- GitHub Actions performs compilation; the target PC is not used as a build machine.
- xbps-src produces proper .xbps packages using Void's kernel packaging template.
- The workflow uses the current void-linux/void-packages master template at build time. It fails safely if the expected compiler-flag insertion point changes.
- This first iteration adds compiler scheduling tuning only. Further tuning should follow validation of the complete current kernel config and real hardware testing.
- Keep your existing working kernel installed until the custom kernel boots and all devices have been tested.
- These are custom packages, not official Void Linux builds.
