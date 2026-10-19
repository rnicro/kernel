#!/bin/sh
set -eu

# The Void container image defaults to the destructive ethereal chroot method.
# Use unprivileged user namespaces so xbps-src can keep its masterdir isolated.
export XBPS_CHROOT_CMD=uunshare

: "${KERNEL_PACKAGE:=linux7.3}"
: "${KERNEL_VERSION:=7.3}"
: "${KERNEL_REVISION:=1}"
: "${BUILD_JOBS:=4}"
: "${VOID_REPO:=https://repo-de.voidlinux.org}"

# Avoid the failing default mirror while preserving HTTPS and XBPS signatures.
mkdir -p /etc/xbps.d
found_repo_config=false
for config in /usr/share/xbps.d/*-repository-*.conf; do
    [ -f "$config" ] || continue
    found_repo_config=true
    sed "s|https://repo-default.voidlinux.org|$VOID_REPO|g" "$config" \
        > "/etc/xbps.d/$(basename "$config")"
done
if [ "$found_repo_config" != true ]; then
    echo "No installed Void repository configuration found" >&2
    exit 1
fi

retry() {
    attempts=0
    until "$@"; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 3 ]; then
            echo "Command failed after 3 attempts: $*" >&2
            return 1
        fi
        sleep "$((attempts * 5))"
    done
}

retry xbps-install -Syu xbps
retry xbps-install -y git base-devel xtools python3 util-linux shadow curl gnupg xz

git clone --depth=1 https://github.com/void-linux/void-packages.git
cd void-packages

# xbps-src expects real directories under hostdir and manages them as chroot
# mount points. Symlinking these paths to Actions cache caused /host/sources
# to exist before xbps-src mounted it, breaking binary-bootstrap reconfiguration.
# Stage cache contents into real directories and sync them back even on failure.
cache_sources=/workspace/cache/sources
cache_repo=/workspace/cache/repocache-x86_64-musl
mkdir -p "$cache_sources" "$cache_repo" hostdir/sources hostdir/repocache-x86_64-musl
cp -a "$cache_sources/." hostdir/sources/
cp -a "$cache_repo/." hostdir/repocache-x86_64-musl/

sync_caches() {
    set +e
    [ ! -d hostdir/sources ] || cp -a hostdir/sources/. "$cache_sources/"
    [ ! -d hostdir/repocache-x86_64-musl ] || cp -a hostdir/repocache-x86_64-musl/. "$cache_repo/"
    [ -z "${gpg_home:-}" ] || rm -rf "$gpg_home"
}
trap sync_caches EXIT HUP INT TERM


# Prefer Void's maintained linux7.3 template. Until it exists upstream, derive
# a local template from linux7.2 but verify the official 7.3 archive signature.
if [ ! -f "srcpkgs/$KERNEL_PACKAGE/template" ]; then
    if [ "$KERNEL_PACKAGE" != "linux7.3" ] || [ "$KERNEL_VERSION" != "7.3" ]; then
        echo "Missing Void kernel template: srcpkgs/$KERNEL_PACKAGE/template" >&2
        exit 1
    fi
    base_package=linux7.2
    base_template="srcpkgs/$base_package/template"
    base_files="srcpkgs/$base_package/files"
    test -f "$base_template" || { echo "Cannot find fallback template: $base_template" >&2; exit 1; }
    test -f "$base_files/x86_64-dotconfig" || { echo "Cannot find fallback x86_64 config" >&2; exit 1; }

    source_dir="hostdir/sources/$KERNEL_PACKAGE-$KERNEL_VERSION"
    mkdir -p "$source_dir"
    archive="$source_dir/linux-$KERNEL_VERSION.tar.xz"
    signature="$source_dir/linux-$KERNEL_VERSION.tar.sign"
    archive_url="https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$KERNEL_VERSION.tar.xz"
    signature_url="https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$KERNEL_VERSION.tar.sign"
    signing_key_id=38DBBDC86092693E
    signing_fingerprint=647F28654894E3BD457199BE38DBBDC86092693E

    gpg_home="$(mktemp -d)"
    GNUPGHOME="$gpg_home" gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$signing_key_id"
    actual_fingerprint="$(GNUPGHOME="$gpg_home" gpg --batch --with-colons --fingerprint "$signing_key_id" | awk -F: '$1 == "fpr" { print $10; exit }')"
    if [ "$actual_fingerprint" != "$signing_fingerprint" ]; then
        echo "Kernel release signing-key fingerprint mismatch: $actual_fingerprint" >&2
        exit 1
    fi

    download_source() {
        curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 --max-time 1800 \
            --output "$archive.part" "$archive_url"
        mv "$archive.part" "$archive"
        curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 --max-time 300 \
            --output "$signature.part" "$signature_url"
        mv "$signature.part" "$signature"
    }

    verified=false
    attempt=1
    verified_tar="$source_dir/linux-$KERNEL_VERSION.tar"
    while [ "$attempt" -le 2 ]; do
        if [ ! -s "$archive" ] || [ ! -s "$signature" ]; then
            download_source
        fi
        if xz -dc "$archive" > "$verified_tar" &&
            GNUPGHOME="$gpg_home" gpg --batch --verify "$signature" "$verified_tar"; then
            verified=true
            rm -f "$verified_tar"
            break
        fi
        echo "Kernel archive verification failed (attempt $attempt); refetching." >&2
        rm -f "$archive" "$signature" "$verified_tar"
        attempt=$((attempt + 1))
    done
    if [ "$verified" != true ]; then
        echo "Could not verify the official Linux $KERNEL_VERSION source archive." >&2
        exit 1
    fi
    checksum="$(sha256sum "$archive" | awk '{ print $1 }')"

    mkdir -p "srcpkgs/$KERNEL_PACKAGE"
    cp -a "$base_files" "srcpkgs/$KERNEL_PACKAGE/"
    python3 - "$base_template" "srcpkgs/$KERNEL_PACKAGE/template" "$KERNEL_PACKAGE" "$KERNEL_VERSION" "$KERNEL_REVISION" "$checksum" <<'PY'
import pathlib
import re
import sys

source, target, package, version, revision, checksum = sys.argv[1:]
text = pathlib.Path(source).read_text()
required = [
    'pkgname=linux7.2',
    'version=7.2.11',
    'case "${version##*.}" in',
    'checksum="',
    'linux7.2-headers_package()',
    'linux7.2-dbg_package()',
]
for item in required:
    if item not in text:
        raise SystemExit(f"Void fallback template layout changed; missing: {item}")

start = text.index('case "${version##*.}" in')
end = text.index('\n\nchecksum=', start)
text = text[:start] + 'distfiles="${KERNEL_SITE}/kernel/v7.x/linux-${version}.tar.xz"' + text[end:]
text = re.sub(r'(?m)^pkgname=.*# The target is pinned to Linux 7.3 mainline; do not auto-upgrade to another series.
pkg="$KERNEL_PACKAGE"
template="srcpkgs/$pkg/template"
config="srcpkgs/$pkg/files/x86_64-dotconfig"
custom_config="srcpkgs/$pkg/files/x86_64-dotconfig-custom"
test -f "$template" || { echo "Missing kernel template: $template" >&2; exit 1; }
test -f "$config" || { echo "Missing x86_64 kernel config: $config" >&2; exit 1; }
echo "Selected Void kernel package: $KERNEL_PACKAGE"

# Apply a production/performance profile to Void's maintained laptop config.
# The Skylake target has 2 cores / 4 hardware threads and a single NUMA node.
# Favor interactive latency under load, avoid server-style NUMA balancing and
# remove selected debug/statistics features that add overhead to normal use.
cp "$config" "$custom_config"
python3 - "$custom_config" <<'PY'
import pathlib
import re
import sys

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
    elif match and ("VIRTIO" in match.group(2) or match.group(2).startswith(("CONFIG_VHOST", "CONFIG_RPMSG", "CONFIG_REMOTEPROC"))):
        # Disable every inherited VirtIO transport/driver and the remoteproc
        # subsystem, whose Kconfig entry selects the VIRTIO core.
        key = match.group(2)
        out.append(f"# {key} is not set")
        seen.add(key)
    else:
        out.append(line)
for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={value}" if value != "n" else f"# {key} is not set")
path.write_text("\n".join(out) + "\n")
PY

# Tune code generation specifically for Skylake; this kernel is not intended for older CPUs.
python3 - "$template" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=."'
new = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=. -march=skylake -mtune=skylake"'
if old not in text:
    if "-mtune=skylake" in text:
        raise SystemExit("Skylake tuning already present; refusing duplicate")
    raise SystemExit("Kernel template KCFLAGS assignment changed; refusing unsafe patch")
text = text.replace(old, new, 1)
oldconfig = "make ${makejobs} ARCH=$arch ${_cross} oldconfig"
newconfig = "make ${makejobs} ARCH=$arch ${_cross} olddefconfig"
if oldconfig not in text:
    raise SystemExit("Kernel template no longer contains expected oldconfig command")
text = text.replace(oldconfig, newconfig)
auditAnchor = "# Always use our revision to CONFIG_LOCALVERSION to match our pkg version."
auditCode = "\n".join([
    "\t# Audit the resolved kernel config after oldconfig, before compilation.",
    '\tfor setting in "CONFIG_EXT4_FS=y" "CONFIG_SWAP=y" "CONFIG_FAT_FS=m" "CONFIG_VFAT_FS=m" "CONFIG_ISO9660_FS=m" "CONFIG_SQUASHFS=m" "CONFIG_USB_STORAGE=m" "CONFIG_USB_UAS=m" "CONFIG_BLK_DEV_SD=m" "CONFIG_DRM_I915=m" "CONFIG_IWLWIFI=m" "CONFIG_R8169=m" "CONFIG_SATA_AHCI=m" "CONFIG_SND_HDA_INTEL=m" "CONFIG_MISC_RTSX_PCI=m" "CONFIG_MMC_REALTEK_PCI=m"; do',
    '\t\tif ! grep -Fxq "$setting" .config; then',
    '\t\t\techo "Required target kernel option missing after oldconfig: $setting" >&2',
    '\t\t\texit 1',
    '\t\tfi',
    '\tdone',
    '\tfor symbol in CONFIG_EXT2_FS CONFIG_EXT3_FS CONFIG_MSDOS_FS CONFIG_UDF_FS CONFIG_EXFAT_FS CONFIG_NTFS_FS CONFIG_NTFS3_FS CONFIG_BTRFS_FS CONFIG_XFS_FS CONFIG_F2FS_FS CONFIG_JFS_FS CONFIG_GFS2_FS CONFIG_OCFS2_FS CONFIG_NILFS2_FS CONFIG_REISERFS_FS CONFIG_ZONEFS_FS CONFIG_HFS_FS CONFIG_HFSPLUS_FS CONFIG_HPFS_FS CONFIG_MINIX_FS CONFIG_QNX4FS_FS CONFIG_QNX6FS_FS CONFIG_SYSV_FS CONFIG_UFS_FS CONFIG_ADFS_FS CONFIG_AFFS_FS CONFIG_BEFS_FS CONFIG_BFS_FS CONFIG_EFS_FS CONFIG_CRAMFS CONFIG_EROFS_FS CONFIG_OMFS_FS CONFIG_ROMFS_FS CONFIG_ORANGEFS_FS CONFIG_ECRYPT_FS CONFIG_NFS_FS CONFIG_CIFS CONFIG_SMBFS CONFIG_SMB_SERVER CONFIG_CEPH_FS CONFIG_CODA_FS CONFIG_AFS_FS CONFIG_9P_FS CONFIG_VBOXSF_FS CONFIG_FUSE_FS CONFIG_OVERLAY_FS CONFIG_INPUT_TOUCHSCREEN CONFIG_TOUCHSCREEN_USB_COMPOSITE CONFIG_MEDIA_SUPPORT CONFIG_MEDIA_CAMERA_SUPPORT CONFIG_VIDEO_DEV CONFIG_USB_VIDEO_CLASS CONFIG_USB_GSPCA CONFIG_USB_PWC CONFIG_SND_PCM_OSS CONFIG_SND_SEQUENCER_OSS CONFIG_KVM CONFIG_KVM_INTEL CONFIG_VHOST CONFIG_VHOST_NET CONFIG_VHOST_VSOCK CONFIG_VHOST_SCSI CONFIG_VHOST_VDPA CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_MMIO CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_VIRTIO_GPU CONFIG_VIRTIO_FS CONFIG_VIRTIO_CONSOLE CONFIG_VIRTIO_INPUT CONFIG_RPMSG_VIRTIO CONFIG_REMOTEPROC CONFIG_REMOTEPROC_CDEV CONFIG_XEN CONFIG_XENFS CONFIG_XEN_VIRTIO CONFIG_HYPERV CONFIG_VBOXGUEST CONFIG_VMWARE_BALLOON CONFIG_VMWARE_VMCI CONFIG_VMWARE_PVSCSI CONFIG_DRM_I915_GVT CONFIG_DRM_I915_GVT_KVMGT; do',
    '\t\tif grep -Eq "^${symbol}=[ym]$" .config; then',
    '\t\t\techo "Unexpected enabled kernel option after oldconfig: ${symbol}" >&2',
    '\t\t\texit 1',
    '\t\tfi',
    '\tdone'
])
if auditAnchor not in text:
    raise SystemExit("Kernel template do_configure audit anchor changed")
if "# Audit the resolved kernel config after oldconfig, before compilation." not in text:
    text = text.replace(auditAnchor, auditAnchor + "\n" + auditCode, 1)
path.write_text(text)
PY

# xbps-src must run unprivileged. Keep bootstrap and package compilation on
# the same isolated user-namespace chroot instead of ethereal, which requires
# the masterdir to be a symlink to / and is inappropriate for a custom masterdir.
if ! id builder >/dev/null 2>&1; then
    useradd -m -U -s /bin/sh builder
fi
chown -R builder:builder /workspace/void-packages
mkdir -p /workspace/artifacts
chown builder:builder /workspace/artifacts

su -s /bin/sh builder -c "
    set -eu
    cd /workspace/void-packages
    # Force the safe chroot style inside the container. -A selects the musl
    # host architecture and its corresponding masterdir-x86_64-musl directory.
    export XBPS_CHROOT_CMD=uunshare
    unset XBPS_ALLOW_CHROOT_BREAKOUT || true
    ./xbps-src -A x86_64-musl binary-bootstrap
    if [ ! -x masterdir-x86_64-musl/usr/bin/bash ]; then
        echo binary-bootstrap_completed_but_target_masterdir_is_not_populated >&2
        echo Expected_masterdir-x86_64-musl_usr_bin_bash >&2
        echo Target_masterdir_marker: >&2
        cat masterdir-x86_64-musl/.xbps_chroot_init >&2 || true
        echo Available_masterdir_directories: >&2
        ls -ld masterdir* >&2 || true
        echo Installed_bootstrap_packages: >&2
        xbps-query -r masterdir-x86_64-musl -l 2>&1 | grep -E '^(base-chroot|base-files|bash|xbps)-' >&2 || true
        exit 1
    fi
    ./xbps-src -A x86_64-musl -j'$BUILD_JOBS' pkg '$KERNEL_PACKAGE'
"

# Publish only the requested installable package family, excluding debug builds.
find hostdir/binpkgs -type f -name "$KERNEL_PACKAGE-*.xbps" ! -name "*-dbg-*.xbps" -print0 \
    | xargs -0 -r cp -v -t /workspace/artifacts
if ! find /workspace/artifacts -maxdepth 1 -type f -name '*.xbps' -print -quit | grep -q .; then
    echo "Build finished without producing installable .xbps packages" >&2
    exit 1
fi
, f'pkgname={package}', text, count=1)
text = re.sub(r'(?m)^version=.*# The target is pinned to Linux 7.3 mainline; do not auto-upgrade to another series.
pkg="$KERNEL_PACKAGE"
template="srcpkgs/$pkg/template"
config="srcpkgs/$pkg/files/x86_64-dotconfig"
custom_config="srcpkgs/$pkg/files/x86_64-dotconfig-custom"
test -f "$template" || { echo "Missing kernel template: $template" >&2; exit 1; }
test -f "$config" || { echo "Missing x86_64 kernel config: $config" >&2; exit 1; }
echo "Selected Void kernel package: $KERNEL_PACKAGE"

# Apply a production/performance profile to Void's maintained laptop config.
# The Skylake target has 2 cores / 4 hardware threads and a single NUMA node.
# Favor interactive latency under load, avoid server-style NUMA balancing and
# remove selected debug/statistics features that add overhead to normal use.
cp "$config" "$custom_config"
python3 - "$custom_config" <<'PY'
import pathlib
import re
import sys

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
    elif match and ("VIRTIO" in match.group(2) or match.group(2).startswith(("CONFIG_VHOST", "CONFIG_RPMSG", "CONFIG_REMOTEPROC"))):
        # Disable every inherited VirtIO transport/driver and the remoteproc
        # subsystem, whose Kconfig entry selects the VIRTIO core.
        key = match.group(2)
        out.append(f"# {key} is not set")
        seen.add(key)
    else:
        out.append(line)
for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={value}" if value != "n" else f"# {key} is not set")
path.write_text("\n".join(out) + "\n")
PY

# Tune code generation specifically for Skylake; this kernel is not intended for older CPUs.
python3 - "$template" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=."'
new = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=. -march=skylake -mtune=skylake"'
if old not in text:
    if "-mtune=skylake" in text:
        raise SystemExit("Skylake tuning already present; refusing duplicate")
    raise SystemExit("Kernel template KCFLAGS assignment changed; refusing unsafe patch")
text = text.replace(old, new, 1)
oldconfig = "make ${makejobs} ARCH=$arch ${_cross} oldconfig"
newconfig = "make ${makejobs} ARCH=$arch ${_cross} olddefconfig"
if oldconfig not in text:
    raise SystemExit("Kernel template no longer contains expected oldconfig command")
text = text.replace(oldconfig, newconfig)
auditAnchor = "# Always use our revision to CONFIG_LOCALVERSION to match our pkg version."
auditCode = "\n".join([
    "\t# Audit the resolved kernel config after oldconfig, before compilation.",
    '\tfor setting in "CONFIG_EXT4_FS=y" "CONFIG_SWAP=y" "CONFIG_FAT_FS=m" "CONFIG_VFAT_FS=m" "CONFIG_ISO9660_FS=m" "CONFIG_SQUASHFS=m" "CONFIG_USB_STORAGE=m" "CONFIG_USB_UAS=m" "CONFIG_BLK_DEV_SD=m" "CONFIG_DRM_I915=m" "CONFIG_IWLWIFI=m" "CONFIG_R8169=m" "CONFIG_SATA_AHCI=m" "CONFIG_SND_HDA_INTEL=m" "CONFIG_MISC_RTSX_PCI=m" "CONFIG_MMC_REALTEK_PCI=m"; do',
    '\t\tif ! grep -Fxq "$setting" .config; then',
    '\t\t\techo "Required target kernel option missing after oldconfig: $setting" >&2',
    '\t\t\texit 1',
    '\t\tfi',
    '\tdone',
    '\tfor symbol in CONFIG_EXT2_FS CONFIG_EXT3_FS CONFIG_MSDOS_FS CONFIG_UDF_FS CONFIG_EXFAT_FS CONFIG_NTFS_FS CONFIG_NTFS3_FS CONFIG_BTRFS_FS CONFIG_XFS_FS CONFIG_F2FS_FS CONFIG_JFS_FS CONFIG_GFS2_FS CONFIG_OCFS2_FS CONFIG_NILFS2_FS CONFIG_REISERFS_FS CONFIG_ZONEFS_FS CONFIG_HFS_FS CONFIG_HFSPLUS_FS CONFIG_HPFS_FS CONFIG_MINIX_FS CONFIG_QNX4FS_FS CONFIG_QNX6FS_FS CONFIG_SYSV_FS CONFIG_UFS_FS CONFIG_ADFS_FS CONFIG_AFFS_FS CONFIG_BEFS_FS CONFIG_BFS_FS CONFIG_EFS_FS CONFIG_CRAMFS CONFIG_EROFS_FS CONFIG_OMFS_FS CONFIG_ROMFS_FS CONFIG_ORANGEFS_FS CONFIG_ECRYPT_FS CONFIG_NFS_FS CONFIG_CIFS CONFIG_SMBFS CONFIG_SMB_SERVER CONFIG_CEPH_FS CONFIG_CODA_FS CONFIG_AFS_FS CONFIG_9P_FS CONFIG_VBOXSF_FS CONFIG_FUSE_FS CONFIG_OVERLAY_FS CONFIG_INPUT_TOUCHSCREEN CONFIG_TOUCHSCREEN_USB_COMPOSITE CONFIG_MEDIA_SUPPORT CONFIG_MEDIA_CAMERA_SUPPORT CONFIG_VIDEO_DEV CONFIG_USB_VIDEO_CLASS CONFIG_USB_GSPCA CONFIG_USB_PWC CONFIG_SND_PCM_OSS CONFIG_SND_SEQUENCER_OSS CONFIG_KVM CONFIG_KVM_INTEL CONFIG_VHOST CONFIG_VHOST_NET CONFIG_VHOST_VSOCK CONFIG_VHOST_SCSI CONFIG_VHOST_VDPA CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_MMIO CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_VIRTIO_GPU CONFIG_VIRTIO_FS CONFIG_VIRTIO_CONSOLE CONFIG_VIRTIO_INPUT CONFIG_RPMSG_VIRTIO CONFIG_REMOTEPROC CONFIG_REMOTEPROC_CDEV CONFIG_XEN CONFIG_XENFS CONFIG_XEN_VIRTIO CONFIG_HYPERV CONFIG_VBOXGUEST CONFIG_VMWARE_BALLOON CONFIG_VMWARE_VMCI CONFIG_VMWARE_PVSCSI CONFIG_DRM_I915_GVT CONFIG_DRM_I915_GVT_KVMGT; do',
    '\t\tif grep -Eq "^${symbol}=[ym]$" .config; then',
    '\t\t\techo "Unexpected enabled kernel option after oldconfig: ${symbol}" >&2',
    '\t\t\texit 1',
    '\t\tfi',
    '\tdone'
])
if auditAnchor not in text:
    raise SystemExit("Kernel template do_configure audit anchor changed")
if "# Audit the resolved kernel config after oldconfig, before compilation." not in text:
    text = text.replace(auditAnchor, auditAnchor + "\n" + auditCode, 1)
path.write_text(text)
PY

# xbps-src must run unprivileged. Keep bootstrap and package compilation on
# the same isolated user-namespace chroot instead of ethereal, which requires
# the masterdir to be a symlink to / and is inappropriate for a custom masterdir.
if ! id builder >/dev/null 2>&1; then
    useradd -m -U -s /bin/sh builder
fi
chown -R builder:builder /workspace/void-packages
mkdir -p /workspace/artifacts
chown builder:builder /workspace/artifacts

su -s /bin/sh builder -c "
    set -eu
    cd /workspace/void-packages
    # Force the safe chroot style inside the container. -A selects the musl
    # host architecture and its corresponding masterdir-x86_64-musl directory.
    export XBPS_CHROOT_CMD=uunshare
    unset XBPS_ALLOW_CHROOT_BREAKOUT || true
    ./xbps-src -A x86_64-musl binary-bootstrap
    if [ ! -x masterdir-x86_64-musl/usr/bin/bash ]; then
        echo binary-bootstrap_completed_but_target_masterdir_is_not_populated >&2
        echo Expected_masterdir-x86_64-musl_usr_bin_bash >&2
        echo Target_masterdir_marker: >&2
        cat masterdir-x86_64-musl/.xbps_chroot_init >&2 || true
        echo Available_masterdir_directories: >&2
        ls -ld masterdir* >&2 || true
        echo Installed_bootstrap_packages: >&2
        xbps-query -r masterdir-x86_64-musl -l 2>&1 | grep -E '^(base-chroot|base-files|bash|xbps)-' >&2 || true
        exit 1
    fi
    ./xbps-src -A x86_64-musl -j'$BUILD_JOBS' pkg '$KERNEL_PACKAGE'
"

# Publish only the requested installable package family, excluding debug builds.
find hostdir/binpkgs -type f -name "$KERNEL_PACKAGE-*.xbps" ! -name "*-dbg-*.xbps" -print0 \
    | xargs -0 -r cp -v -t /workspace/artifacts
if ! find /workspace/artifacts -maxdepth 1 -type f -name '*.xbps' -print -quit | grep -q .; then
    echo "Build finished without producing installable .xbps packages" >&2
    exit 1
fi
, f'version={version}', text, count=1)
text = re.sub(r'(?m)^revision=.*# The target is pinned to Linux 7.3 mainline; do not auto-upgrade to another series.
pkg="$KERNEL_PACKAGE"
template="srcpkgs/$pkg/template"
config="srcpkgs/$pkg/files/x86_64-dotconfig"
custom_config="srcpkgs/$pkg/files/x86_64-dotconfig-custom"
test -f "$template" || { echo "Missing kernel template: $template" >&2; exit 1; }
test -f "$config" || { echo "Missing x86_64 kernel config: $config" >&2; exit 1; }
echo "Selected Void kernel package: $KERNEL_PACKAGE"

# Apply a production/performance profile to Void's maintained laptop config.
# The Skylake target has 2 cores / 4 hardware threads and a single NUMA node.
# Favor interactive latency under load, avoid server-style NUMA balancing and
# remove selected debug/statistics features that add overhead to normal use.
cp "$config" "$custom_config"
python3 - "$custom_config" <<'PY'
import pathlib
import re
import sys

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
    elif match and ("VIRTIO" in match.group(2) or match.group(2).startswith(("CONFIG_VHOST", "CONFIG_RPMSG", "CONFIG_REMOTEPROC"))):
        # Disable every inherited VirtIO transport/driver and the remoteproc
        # subsystem, whose Kconfig entry selects the VIRTIO core.
        key = match.group(2)
        out.append(f"# {key} is not set")
        seen.add(key)
    else:
        out.append(line)
for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={value}" if value != "n" else f"# {key} is not set")
path.write_text("\n".join(out) + "\n")
PY

# Tune code generation specifically for Skylake; this kernel is not intended for older CPUs.
python3 - "$template" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=."'
new = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=. -march=skylake -mtune=skylake"'
if old not in text:
    if "-mtune=skylake" in text:
        raise SystemExit("Skylake tuning already present; refusing duplicate")
    raise SystemExit("Kernel template KCFLAGS assignment changed; refusing unsafe patch")
text = text.replace(old, new, 1)
oldconfig = "make ${makejobs} ARCH=$arch ${_cross} oldconfig"
newconfig = "make ${makejobs} ARCH=$arch ${_cross} olddefconfig"
if oldconfig not in text:
    raise SystemExit("Kernel template no longer contains expected oldconfig command")
text = text.replace(oldconfig, newconfig)
auditAnchor = "# Always use our revision to CONFIG_LOCALVERSION to match our pkg version."
auditCode = "\n".join([
    "\t# Audit the resolved kernel config after oldconfig, before compilation.",
    '\tfor setting in "CONFIG_EXT4_FS=y" "CONFIG_SWAP=y" "CONFIG_FAT_FS=m" "CONFIG_VFAT_FS=m" "CONFIG_ISO9660_FS=m" "CONFIG_SQUASHFS=m" "CONFIG_USB_STORAGE=m" "CONFIG_USB_UAS=m" "CONFIG_BLK_DEV_SD=m" "CONFIG_DRM_I915=m" "CONFIG_IWLWIFI=m" "CONFIG_R8169=m" "CONFIG_SATA_AHCI=m" "CONFIG_SND_HDA_INTEL=m" "CONFIG_MISC_RTSX_PCI=m" "CONFIG_MMC_REALTEK_PCI=m"; do',
    '\t\tif ! grep -Fxq "$setting" .config; then',
    '\t\t\techo "Required target kernel option missing after oldconfig: $setting" >&2',
    '\t\t\texit 1',
    '\t\tfi',
    '\tdone',
    '\tfor symbol in CONFIG_EXT2_FS CONFIG_EXT3_FS CONFIG_MSDOS_FS CONFIG_UDF_FS CONFIG_EXFAT_FS CONFIG_NTFS_FS CONFIG_NTFS3_FS CONFIG_BTRFS_FS CONFIG_XFS_FS CONFIG_F2FS_FS CONFIG_JFS_FS CONFIG_GFS2_FS CONFIG_OCFS2_FS CONFIG_NILFS2_FS CONFIG_REISERFS_FS CONFIG_ZONEFS_FS CONFIG_HFS_FS CONFIG_HFSPLUS_FS CONFIG_HPFS_FS CONFIG_MINIX_FS CONFIG_QNX4FS_FS CONFIG_QNX6FS_FS CONFIG_SYSV_FS CONFIG_UFS_FS CONFIG_ADFS_FS CONFIG_AFFS_FS CONFIG_BEFS_FS CONFIG_BFS_FS CONFIG_EFS_FS CONFIG_CRAMFS CONFIG_EROFS_FS CONFIG_OMFS_FS CONFIG_ROMFS_FS CONFIG_ORANGEFS_FS CONFIG_ECRYPT_FS CONFIG_NFS_FS CONFIG_CIFS CONFIG_SMBFS CONFIG_SMB_SERVER CONFIG_CEPH_FS CONFIG_CODA_FS CONFIG_AFS_FS CONFIG_9P_FS CONFIG_VBOXSF_FS CONFIG_FUSE_FS CONFIG_OVERLAY_FS CONFIG_INPUT_TOUCHSCREEN CONFIG_TOUCHSCREEN_USB_COMPOSITE CONFIG_MEDIA_SUPPORT CONFIG_MEDIA_CAMERA_SUPPORT CONFIG_VIDEO_DEV CONFIG_USB_VIDEO_CLASS CONFIG_USB_GSPCA CONFIG_USB_PWC CONFIG_SND_PCM_OSS CONFIG_SND_SEQUENCER_OSS CONFIG_KVM CONFIG_KVM_INTEL CONFIG_VHOST CONFIG_VHOST_NET CONFIG_VHOST_VSOCK CONFIG_VHOST_SCSI CONFIG_VHOST_VDPA CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_MMIO CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_VIRTIO_GPU CONFIG_VIRTIO_FS CONFIG_VIRTIO_CONSOLE CONFIG_VIRTIO_INPUT CONFIG_RPMSG_VIRTIO CONFIG_REMOTEPROC CONFIG_REMOTEPROC_CDEV CONFIG_XEN CONFIG_XENFS CONFIG_XEN_VIRTIO CONFIG_HYPERV CONFIG_VBOXGUEST CONFIG_VMWARE_BALLOON CONFIG_VMWARE_VMCI CONFIG_VMWARE_PVSCSI CONFIG_DRM_I915_GVT CONFIG_DRM_I915_GVT_KVMGT; do',
    '\t\tif grep -Eq "^${symbol}=[ym]$" .config; then',
    '\t\t\techo "Unexpected enabled kernel option after oldconfig: ${symbol}" >&2',
    '\t\t\texit 1',
    '\t\tfi',
    '\tdone'
])
if auditAnchor not in text:
    raise SystemExit("Kernel template do_configure audit anchor changed")
if "# Audit the resolved kernel config after oldconfig, before compilation." not in text:
    text = text.replace(auditAnchor, auditAnchor + "\n" + auditCode, 1)
path.write_text(text)
PY

# xbps-src must run unprivileged. Keep bootstrap and package compilation on
# the same isolated user-namespace chroot instead of ethereal, which requires
# the masterdir to be a symlink to / and is inappropriate for a custom masterdir.
if ! id builder >/dev/null 2>&1; then
    useradd -m -U -s /bin/sh builder
fi
chown -R builder:builder /workspace/void-packages
mkdir -p /workspace/artifacts
chown builder:builder /workspace/artifacts

su -s /bin/sh builder -c "
    set -eu
    cd /workspace/void-packages
    # Force the safe chroot style inside the container. -A selects the musl
    # host architecture and its corresponding masterdir-x86_64-musl directory.
    export XBPS_CHROOT_CMD=uunshare
    unset XBPS_ALLOW_CHROOT_BREAKOUT || true
    ./xbps-src -A x86_64-musl binary-bootstrap
    if [ ! -x masterdir-x86_64-musl/usr/bin/bash ]; then
        echo binary-bootstrap_completed_but_target_masterdir_is_not_populated >&2
        echo Expected_masterdir-x86_64-musl_usr_bin_bash >&2
        echo Target_masterdir_marker: >&2
        cat masterdir-x86_64-musl/.xbps_chroot_init >&2 || true
        echo Available_masterdir_directories: >&2
        ls -ld masterdir* >&2 || true
        echo Installed_bootstrap_packages: >&2
        xbps-query -r masterdir-x86_64-musl -l 2>&1 | grep -E '^(base-chroot|base-files|bash|xbps)-' >&2 || true
        exit 1
    fi
    ./xbps-src -A x86_64-musl -j'$BUILD_JOBS' pkg '$KERNEL_PACKAGE'
"

# Publish only the requested installable package family, excluding debug builds.
find hostdir/binpkgs -type f -name "$KERNEL_PACKAGE-*.xbps" ! -name "*-dbg-*.xbps" -print0 \
    | xargs -0 -r cp -v -t /workspace/artifacts
if ! find /workspace/artifacts -maxdepth 1 -type f -name '*.xbps' -print -quit | grep -q .; then
    echo "Build finished without producing installable .xbps packages" >&2
    exit 1
fi
, f'revision={revision}', text, count=1)
text = re.sub(r'(?ms)^checksum=".*?"', f'checksum="{checksum}"', text, count=1)
text = re.sub(r'(?m)^linux7[.]2(?=-)', package, text)
if 'linux7.2' in text or f'pkgname={package}' not in text:
    raise SystemExit("Failed to adapt fallback template package names safely")
pathlib.Path(target).write_text(text)
PY
    rm -rf "$gpg_home"
    gpg_home=
fi

# The target is pinned to Linux 7.3 mainline; do not auto-upgrade to another series.
pkg="$KERNEL_PACKAGE"
template="srcpkgs/$pkg/template"
config="srcpkgs/$pkg/files/x86_64-dotconfig"
custom_config="srcpkgs/$pkg/files/x86_64-dotconfig-custom"
test -f "$template" || { echo "Missing kernel template: $template" >&2; exit 1; }
test -f "$config" || { echo "Missing x86_64 kernel config: $config" >&2; exit 1; }
echo "Selected Void kernel package: $KERNEL_PACKAGE"

# Apply a production/performance profile to Void's maintained laptop config.
# The Skylake target has 2 cores / 4 hardware threads and a single NUMA node.
# Favor interactive latency under load, avoid server-style NUMA balancing and
# remove selected debug/statistics features that add overhead to normal use.
cp "$config" "$custom_config"
python3 - "$custom_config" <<'PY'
import pathlib
import re
import sys

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
    elif match and ("VIRTIO" in match.group(2) or match.group(2).startswith(("CONFIG_VHOST", "CONFIG_RPMSG", "CONFIG_REMOTEPROC"))):
        # Disable every inherited VirtIO transport/driver and the remoteproc
        # subsystem, whose Kconfig entry selects the VIRTIO core.
        key = match.group(2)
        out.append(f"# {key} is not set")
        seen.add(key)
    else:
        out.append(line)
for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={value}" if value != "n" else f"# {key} is not set")
path.write_text("\n".join(out) + "\n")
PY

# Tune code generation specifically for Skylake; this kernel is not intended for older CPUs.
python3 - "$template" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=."'
new = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=. -march=skylake -mtune=skylake"'
if old not in text:
    if "-mtune=skylake" in text:
        raise SystemExit("Skylake tuning already present; refusing duplicate")
    raise SystemExit("Kernel template KCFLAGS assignment changed; refusing unsafe patch")
text = text.replace(old, new, 1)
oldconfig = "make ${makejobs} ARCH=$arch ${_cross} oldconfig"
newconfig = "make ${makejobs} ARCH=$arch ${_cross} olddefconfig"
if oldconfig not in text:
    raise SystemExit("Kernel template no longer contains expected oldconfig command")
text = text.replace(oldconfig, newconfig)
auditAnchor = "# Always use our revision to CONFIG_LOCALVERSION to match our pkg version."
auditCode = "\n".join([
    "\t# Audit the resolved kernel config after oldconfig, before compilation.",
    '\tfor setting in "CONFIG_EXT4_FS=y" "CONFIG_SWAP=y" "CONFIG_FAT_FS=m" "CONFIG_VFAT_FS=m" "CONFIG_ISO9660_FS=m" "CONFIG_SQUASHFS=m" "CONFIG_USB_STORAGE=m" "CONFIG_USB_UAS=m" "CONFIG_BLK_DEV_SD=m" "CONFIG_DRM_I915=m" "CONFIG_IWLWIFI=m" "CONFIG_R8169=m" "CONFIG_SATA_AHCI=m" "CONFIG_SND_HDA_INTEL=m" "CONFIG_MISC_RTSX_PCI=m" "CONFIG_MMC_REALTEK_PCI=m"; do',
    '\t\tif ! grep -Fxq "$setting" .config; then',
    '\t\t\techo "Required target kernel option missing after oldconfig: $setting" >&2',
    '\t\t\texit 1',
    '\t\tfi',
    '\tdone',
    '\tfor symbol in CONFIG_EXT2_FS CONFIG_EXT3_FS CONFIG_MSDOS_FS CONFIG_UDF_FS CONFIG_EXFAT_FS CONFIG_NTFS_FS CONFIG_NTFS3_FS CONFIG_BTRFS_FS CONFIG_XFS_FS CONFIG_F2FS_FS CONFIG_JFS_FS CONFIG_GFS2_FS CONFIG_OCFS2_FS CONFIG_NILFS2_FS CONFIG_REISERFS_FS CONFIG_ZONEFS_FS CONFIG_HFS_FS CONFIG_HFSPLUS_FS CONFIG_HPFS_FS CONFIG_MINIX_FS CONFIG_QNX4FS_FS CONFIG_QNX6FS_FS CONFIG_SYSV_FS CONFIG_UFS_FS CONFIG_ADFS_FS CONFIG_AFFS_FS CONFIG_BEFS_FS CONFIG_BFS_FS CONFIG_EFS_FS CONFIG_CRAMFS CONFIG_EROFS_FS CONFIG_OMFS_FS CONFIG_ROMFS_FS CONFIG_ORANGEFS_FS CONFIG_ECRYPT_FS CONFIG_NFS_FS CONFIG_CIFS CONFIG_SMBFS CONFIG_SMB_SERVER CONFIG_CEPH_FS CONFIG_CODA_FS CONFIG_AFS_FS CONFIG_9P_FS CONFIG_VBOXSF_FS CONFIG_FUSE_FS CONFIG_OVERLAY_FS CONFIG_INPUT_TOUCHSCREEN CONFIG_TOUCHSCREEN_USB_COMPOSITE CONFIG_MEDIA_SUPPORT CONFIG_MEDIA_CAMERA_SUPPORT CONFIG_VIDEO_DEV CONFIG_USB_VIDEO_CLASS CONFIG_USB_GSPCA CONFIG_USB_PWC CONFIG_SND_PCM_OSS CONFIG_SND_SEQUENCER_OSS CONFIG_KVM CONFIG_KVM_INTEL CONFIG_VHOST CONFIG_VHOST_NET CONFIG_VHOST_VSOCK CONFIG_VHOST_SCSI CONFIG_VHOST_VDPA CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_MMIO CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_VIRTIO_GPU CONFIG_VIRTIO_FS CONFIG_VIRTIO_CONSOLE CONFIG_VIRTIO_INPUT CONFIG_RPMSG_VIRTIO CONFIG_REMOTEPROC CONFIG_REMOTEPROC_CDEV CONFIG_XEN CONFIG_XENFS CONFIG_XEN_VIRTIO CONFIG_HYPERV CONFIG_VBOXGUEST CONFIG_VMWARE_BALLOON CONFIG_VMWARE_VMCI CONFIG_VMWARE_PVSCSI CONFIG_DRM_I915_GVT CONFIG_DRM_I915_GVT_KVMGT; do',
    '\t\tif grep -Eq "^${symbol}=[ym]$" .config; then',
    '\t\t\techo "Unexpected enabled kernel option after oldconfig: ${symbol}" >&2',
    '\t\t\texit 1',
    '\t\tfi',
    '\tdone'
])
if auditAnchor not in text:
    raise SystemExit("Kernel template do_configure audit anchor changed")
if "# Audit the resolved kernel config after oldconfig, before compilation." not in text:
    text = text.replace(auditAnchor, auditAnchor + "\n" + auditCode, 1)
path.write_text(text)
PY

# xbps-src must run unprivileged. Keep bootstrap and package compilation on
# the same isolated user-namespace chroot instead of ethereal, which requires
# the masterdir to be a symlink to / and is inappropriate for a custom masterdir.
if ! id builder >/dev/null 2>&1; then
    useradd -m -U -s /bin/sh builder
fi
chown -R builder:builder /workspace/void-packages
mkdir -p /workspace/artifacts
chown builder:builder /workspace/artifacts

su -s /bin/sh builder -c "
    set -eu
    cd /workspace/void-packages
    # Force the safe chroot style inside the container. -A selects the musl
    # host architecture and its corresponding masterdir-x86_64-musl directory.
    export XBPS_CHROOT_CMD=uunshare
    unset XBPS_ALLOW_CHROOT_BREAKOUT || true
    ./xbps-src -A x86_64-musl binary-bootstrap
    if [ ! -x masterdir-x86_64-musl/usr/bin/bash ]; then
        echo binary-bootstrap_completed_but_target_masterdir_is_not_populated >&2
        echo Expected_masterdir-x86_64-musl_usr_bin_bash >&2
        echo Target_masterdir_marker: >&2
        cat masterdir-x86_64-musl/.xbps_chroot_init >&2 || true
        echo Available_masterdir_directories: >&2
        ls -ld masterdir* >&2 || true
        echo Installed_bootstrap_packages: >&2
        xbps-query -r masterdir-x86_64-musl -l 2>&1 | grep -E '^(base-chroot|base-files|bash|xbps)-' >&2 || true
        exit 1
    fi
    ./xbps-src -A x86_64-musl -j'$BUILD_JOBS' pkg '$KERNEL_PACKAGE'
"

# Publish only the requested installable package family, excluding debug builds.
find hostdir/binpkgs -type f -name "$KERNEL_PACKAGE-*.xbps" ! -name "*-dbg-*.xbps" -print0 \
    | xargs -0 -r cp -v -t /workspace/artifacts
if ! find /workspace/artifacts -maxdepth 1 -type f -name '*.xbps' -print -quit | grep -q .; then
    echo "Build finished without producing installable .xbps packages" >&2
    exit 1
fi
