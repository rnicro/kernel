import pathlib
import re
import sys

# Newer kernel Kconfig files may add vendor menus absent from the older
# baseline config. Normalize the resolved config, then run olddefconfig again.
RESOLVED_DISABLE = {
    "CONFIG_ETHERNET",
    "CONFIG_R8169",
    "CONFIG_SCSI_BNX2_ISCSI",
    "CONFIG_SCSI_BNX2X_FCOE",
    "CONFIG_SCSI_CXGB3_ISCSI",
    "CONFIG_SCSI_CXGB4_ISCSI",
}

def normalize_resolved(path: pathlib.Path) -> None:
    lines = path.read_text().splitlines()
    out = []
    for line in lines:
        match = re.match(r"^(?:# )?(CONFIG_[A-Z0-9_]+)(?:=[ym]| is not set)$", line)
        if match:
            symbol = match.group(1)
            dynamic_vendor = symbol.startswith("CONFIG_NET_VENDOR_") or (
                symbol.startswith("CONFIG_WLAN_VENDOR_")
                and symbol != "CONFIG_WLAN_VENDOR_INTEL"
            )
            if symbol in RESOLVED_DISABLE or dynamic_vendor:
                out.append(f"# {symbol} is not set")
                continue
        out.append(line)
    path.write_text("\n".join(out) + "\n")

if len(sys.argv) == 3 and sys.argv[1] == "--normalize-resolved":
    normalize_resolved(pathlib.Path(sys.argv[2]))
    raise SystemExit(0)
if len(sys.argv) != 2:
    raise SystemExit("usage: optimize-kernel-config.py [--normalize-resolved] CONFIG")

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
values = {
    # Fast interactive scheduling; idle CPUs still stop periodic ticks.
    "CONFIG_HZ_100": "n",
    "CONFIG_HZ_250": "n",
    "CONFIG_HZ_300": "n",
    "CONFIG_HZ_1000": "y",
    "CONFIG_HZ": "1000",
    "CONFIG_NO_HZ_IDLE": "y",
    "CONFIG_NO_HZ_FULL": "n",
    # Make Intel P-state start in the performance governor; schedutil remains
    # built so it can be selected later if battery life is more important.
    "CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE": "y",
    "CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL": "n",
    "CONFIG_CPU_FREQ_GOV_PERFORMANCE": "y",
    "CONFIG_CPU_FREQ_GOV_SCHEDUTIL": "y",
    "CONFIG_X86_INTEL_PSTATE": "y",
    "CONFIG_INTEL_IDLE": "y",
    # Fit static CPU tables and scheduling to the device's 4 logical CPUs.
    "CONFIG_NR_CPUS": "4",
    "CONFIG_NUMA_BALANCING": "n",
    "CONFIG_NUMA_BALANCING_DEFAULT_ENABLED": "n",
    # Disable instrumentation/debug checks that are not useful in the daily
    # performance kernel and can add allocator/scheduler/PM overhead.
    "CONFIG_SCHED_INFO": "n",
    "CONFIG_SCHEDSTATS": "n",
    "CONFIG_DEBUG_PREEMPT": "n",
    "CONFIG_DEBUG_VIRTUAL": "n",
    "CONFIG_DEBUG_WX": "n",
    "CONFIG_DEBUG_MEMORY_INIT": "n",
    "CONFIG_PAGE_POISONING": "n",
    "CONFIG_SLUB_DEBUG": "n",
    "CONFIG_KFENCE": "n",
    "CONFIG_PM_DEBUG": "n",
    "CONFIG_PM_SLEEP_DEBUG": "n",
    "CONFIG_PM_TRACE": "n",
    "CONFIG_PM_TRACE_RTC": "n",
    # Remove DWARF/BTF metadata from this performance build to reduce build time
    # and package size; this profile does not need an embedded-debug kernel.
    "CONFIG_DEBUG_INFO_NONE": "y",
    "CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT": "n",
    "CONFIG_DEBUG_INFO_DWARF4": "n",
    "CONFIG_DEBUG_INFO_DWARF5": "n",
    "CONFIG_DEBUG_INFO_BTF": "n",
    "CONFIG_DEBUG_INFO_BTF_MODULES": "n",
    "CONFIG_GDB_SCRIPTS": "n",
    # The laptop uses Intel HD Graphics 520 (i915), not these alternate GPU stacks.
    "CONFIG_DRM_AMDGPU": "n",
    "CONFIG_DRM_RADEON": "n",
    "CONFIG_DRM_NOUVEAU": "n",
    "CONFIG_DRM_VMWGFX": "n",
    "CONFIG_DRM_VIRTIO_GPU": "n",
    "CONFIG_DRM_QXL": "n",
    "CONFIG_DRM_GMA500": "n",
    "CONFIG_DRM_AST": "n",
    "CONFIG_DRM_MGAG200": "n",
    "CONFIG_DRM_CIRRUS_QEMU": "n",
    "CONFIG_DRM_BOCHS": "n",
    "CONFIG_DRM_VBOXVIDEO": "n",
    "CONFIG_DRM_XE": "n",
    "CONFIG_NUMA": "n",
    # Filesystem allowlist: ext4 root, FAT/VFAT, and OS installer media only.
    "CONFIG_EXT4_FS": "y",
    "CONFIG_EXT2_FS": "n",
    "CONFIG_EXT3_FS": "n",
    "CONFIG_FAT_FS": "m",
    "CONFIG_MSDOS_FS": "n",
    "CONFIG_VFAT_FS": "m",
    "CONFIG_ISO9660_FS": "m",
    "CONFIG_SQUASHFS": "m",
    "CONFIG_UDF_FS": "n",
    "CONFIG_EXFAT_FS": "n",
    "CONFIG_NTFS_FS": "n",
    "CONFIG_NTFS3_FS": "n",
    "CONFIG_BTRFS_FS": "n",
    "CONFIG_XFS_FS": "n",
    "CONFIG_F2FS_FS": "n",
    "CONFIG_JFS_FS": "n",
    "CONFIG_GFS2_FS": "n",
    "CONFIG_OCFS2_FS": "n",
    "CONFIG_NILFS2_FS": "n",
    "CONFIG_REISERFS_FS": "n",
    "CONFIG_ZONEFS_FS": "n",
    "CONFIG_HFS_FS": "n",
    "CONFIG_HFSPLUS_FS": "n",
    "CONFIG_HPFS_FS": "n",
    "CONFIG_MINIX_FS": "n",
    "CONFIG_QNX4FS_FS": "n",
    "CONFIG_QNX6FS_FS": "n",
    "CONFIG_SYSV_FS": "n",
    "CONFIG_UFS_FS": "n",
    "CONFIG_ADFS_FS": "n",
    "CONFIG_AFFS_FS": "n",
    "CONFIG_BEFS_FS": "n",
    "CONFIG_BFS_FS": "n",
    "CONFIG_EFS_FS": "n",
    "CONFIG_CRAMFS": "n",
    "CONFIG_EROFS_FS": "n",
    "CONFIG_OMFS_FS": "n",
    "CONFIG_ROMFS_FS": "n",
    "CONFIG_ORANGEFS_FS": "n",
    "CONFIG_ECRYPT_FS": "n",
    "CONFIG_NFS_FS": "n",
    "CONFIG_CIFS": "n",
    "CONFIG_SMBFS": "n",
    "CONFIG_SMB_SERVER": "n",
    "CONFIG_CEPH_FS": "n",
    "CONFIG_CODA_FS": "n",
    "CONFIG_AFS_FS": "n",
    "CONFIG_9P_FS": "n",
    "CONFIG_VBOXSF_FS": "n",
    "CONFIG_FUSE_FS": "n",
    "CONFIG_OVERLAY_FS": "n",
    # No touchscreen, webcam/video capture, or legacy OSS audio emulation.
    "CONFIG_INPUT_TOUCHSCREEN": "n",
    "CONFIG_TOUCHSCREEN_USB_COMPOSITE": "n",
    "CONFIG_MEDIA_SUPPORT": "n",
    "CONFIG_MEDIA_CAMERA_SUPPORT": "n",
    "CONFIG_VIDEO_DEV": "n",
    "CONFIG_USB_VIDEO_CLASS": "n",
    "CONFIG_USB_GSPCA": "n",
    "CONFIG_USB_PWC": "n",
    "CONFIG_SND_PCM_OSS": "n",
    "CONFIG_SND_SEQUENCER_OSS": "n",
    "CONFIG_ETHERNET": "n",
    "CONFIG_R8169": "n",
    # These storage transports select ETHERNET or require it; with no wired
    # networking, leaving them enabled forces Kconfig to resurrect drivers.
    "CONFIG_SCSI_BNX2_ISCSI": "n",
    "CONFIG_SCSI_BNX2X_FCOE": "n",
    "CONFIG_SCSI_CXGB3_ISCSI": "n",
    "CONFIG_SCSI_CXGB4_ISCSI": "n",
    # No VM/container usage: disable host/guest virtualization-only drivers.
    "CONFIG_KVM": "n",
    "CONFIG_KVM_INTEL": "n",
    "CONFIG_REMOTEPROC": "n",
    "CONFIG_REMOTEPROC_CDEV": "n",
    "CONFIG_VHOST": "n",
    "CONFIG_VHOST_NET": "n",
    "CONFIG_VHOST_VSOCK": "n",
    "CONFIG_VHOST_SCSI": "n",
    "CONFIG_VHOST_VDPA": "n",
    "CONFIG_VHOST_RING": "n",
    "CONFIG_VHOST_IOTLB": "n",
    "CONFIG_RPMSG_VIRTIO": "n",
    "CONFIG_VIRTIO": "n",
    "CONFIG_VIRTIO_PCI": "n",
    "CONFIG_VIRTIO_MMIO": "n",
    "CONFIG_VIRTIO_BLK": "n",
    "CONFIG_VIRTIO_NET": "n",
    "CONFIG_VIRTIO_GPU": "n",
    "CONFIG_VIRTIO_FS": "n",
    "CONFIG_VIRTIO_CONSOLE": "n",
    "CONFIG_VIRTIO_INPUT": "n",
    "CONFIG_XEN": "n",
    "CONFIG_XENFS": "n",
    "CONFIG_XEN_VIRTIO": "n",
    "CONFIG_HYPERV": "n",
    "CONFIG_VBOXGUEST": "n",
    "CONFIG_VMWARE_BALLOON": "n",
    "CONFIG_VMWARE_VMCI": "n",
    "CONFIG_VMWARE_PVSCSI": "n",
    "CONFIG_DRM_I915_GVT": "n",
    "CONFIG_DRM_I915_GVT_KVMGT": "n",
    "CONFIG_LOCALVERSION_AUTO": "n",
}
seen = set()
out = []
for line in lines:
    match = re.match(r"(# )?(CONFIG_[A-Z0-9_]+)(?:=| is not set)", line)
    if match and match.group(2) in values:
        key = match.group(2)
        value = values[key]
        out.append(f"{key}={value}" if value != "n" else f"# {key} is not set")
        seen.add(key)
    elif match and (
        "VIRTIO" in match.group(2)
        or match.group(2).startswith(("CONFIG_VHOST", "CONFIG_RPMSG", "CONFIG_REMOTEPROC"))
        or match.group(2).startswith("CONFIG_NET_VENDOR_")
        or (match.group(2).startswith("CONFIG_WLAN_VENDOR_") and match.group(2) != "CONFIG_WLAN_VENDOR_INTEL")
    ):
        # Wired Ethernet is unused; retain only Intel Wi-Fi and separately configured
        # Realtek PCI card-reader support.
        key = match.group(2)
        out.append(f"# {key} is not set")
        seen.add(key)
    else:
        out.append(line)
for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={value}" if value != "n" else f"# {key} is not set")
path.write_text("\n".join(out) + "\n")