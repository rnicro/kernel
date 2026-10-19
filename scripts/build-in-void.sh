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
cache_ccache=/workspace/cache/ccache
mkdir -p "$cache_sources" "$cache_repo" "$cache_ccache" hostdir/sources hostdir/repocache-x86_64-musl hostdir/ccache
cp -a "$cache_sources/." hostdir/sources/
cp -a "$cache_repo/." hostdir/repocache-x86_64-musl/
cp -a "$cache_ccache/." hostdir/ccache/
# Bound persistent compiler-cache growth while retaining cross-run hits.
printf "max_size = 2.0G\ncompression = true\n" > hostdir/ccache/ccache.conf

sync_caches() {
    set +e
    [ ! -d hostdir/sources ] || cp -a hostdir/sources/. "$cache_sources/"
    [ ! -d hostdir/repocache-x86_64-musl ] || cp -a hostdir/repocache-x86_64-musl/. "$cache_repo/"
    [ ! -d hostdir/ccache ] || cp -a hostdir/ccache/. "$cache_ccache/"
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
text = re.sub(r'(?m)^pkgname=.*$', f'pkgname={package}', text, count=1)
text = re.sub(r'(?m)^version=.*$', f'version={version}', text, count=1)
text = re.sub(r'(?m)^revision=.*$', f'revision={revision}', text, count=1)
text = re.sub(r'(?ms)^checksum=".*?"', f'checksum="{checksum}"', text, count=1)
text = text.replace('linux7.2', package)
if f'pkgname={package}' not in text or 'linux7.2' in text:
    raise SystemExit("Failed to adapt fallback template package names safely")
pathlib.Path(target).write_text(text)
PY
    rm -rf "$gpg_home"
    gpg_home=
fi

# Linux 7.3 is pinned explicitly above; no floating kernel-series selection.
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
# Apply the target kernel profile with a separately tested, idempotent transformer.
python3 /workspace/scripts/optimize-kernel-config.py "$custom_config"
cp /workspace/scripts/optimize-kernel-config.py "srcpkgs/$KERNEL_PACKAGE/files/optimize-kernel-config.py"

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
    "\t# Normalize vendor menus newly introduced since the baseline config.",
    '\tpython3 ${FILESDIR}/optimize-kernel-config.py --normalize-resolved .config',
    '\tmake ${makejobs} ARCH=$arch ${_cross} olddefconfig',
    '\tfor setting in "CONFIG_EXT4_FS=y" "CONFIG_SWAP=y" "CONFIG_FAT_FS=m" "CONFIG_VFAT_FS=m" "CONFIG_ISO9660_FS=m" "CONFIG_SQUASHFS=m" "CONFIG_USB_STORAGE=m" "CONFIG_USB_UAS=m" "CONFIG_BLK_DEV_SD=m" "CONFIG_DRM_I915=m" "CONFIG_IWLWIFI=m" "CONFIG_SATA_AHCI=m" "CONFIG_SND_HDA_INTEL=m" "CONFIG_MISC_RTSX_PCI=m" "CONFIG_MMC_REALTEK_PCI=m" "CONFIG_WLAN_VENDOR_INTEL=y"; do',
    '\t\tif ! grep -Fxq "$setting" .config; then',
    '\t\t\techo "Required target kernel option missing after oldconfig: $setting" >&2',
    '\t\t\texit 1',
    '\t\tfi',
    '\tdone',
    '\tfor symbol in CONFIG_EXT2_FS CONFIG_EXT3_FS CONFIG_MSDOS_FS CONFIG_UDF_FS CONFIG_EXFAT_FS CONFIG_NTFS_FS CONFIG_NTFS3_FS CONFIG_BTRFS_FS CONFIG_XFS_FS CONFIG_F2FS_FS CONFIG_JFS_FS CONFIG_GFS2_FS CONFIG_OCFS2_FS CONFIG_NILFS2_FS CONFIG_REISERFS_FS CONFIG_ZONEFS_FS CONFIG_HFS_FS CONFIG_HFSPLUS_FS CONFIG_HPFS_FS CONFIG_MINIX_FS CONFIG_QNX4FS_FS CONFIG_QNX6FS_FS CONFIG_SYSV_FS CONFIG_UFS_FS CONFIG_ADFS_FS CONFIG_AFFS_FS CONFIG_BEFS_FS CONFIG_BFS_FS CONFIG_EFS_FS CONFIG_CRAMFS CONFIG_EROFS_FS CONFIG_OMFS_FS CONFIG_ROMFS_FS CONFIG_ORANGEFS_FS CONFIG_ECRYPT_FS CONFIG_NFS_FS CONFIG_CIFS CONFIG_SMBFS CONFIG_SMB_SERVER CONFIG_CEPH_FS CONFIG_CODA_FS CONFIG_AFS_FS CONFIG_9P_FS CONFIG_VBOXSF_FS CONFIG_FUSE_FS CONFIG_OVERLAY_FS CONFIG_INPUT_TOUCHSCREEN CONFIG_TOUCHSCREEN_USB_COMPOSITE CONFIG_MEDIA_SUPPORT CONFIG_MEDIA_CAMERA_SUPPORT CONFIG_VIDEO_DEV CONFIG_USB_VIDEO_CLASS CONFIG_USB_GSPCA CONFIG_USB_PWC CONFIG_SND_PCM_OSS CONFIG_SND_SEQUENCER_OSS CONFIG_ETHERNET CONFIG_R8169 CONFIG_SCSI_BNX2_ISCSI CONFIG_SCSI_BNX2X_FCOE CONFIG_SCSI_CXGB3_ISCSI CONFIG_SCSI_CXGB4_ISCSI CONFIG_KVM CONFIG_KVM_INTEL CONFIG_VHOST CONFIG_VHOST_NET CONFIG_VHOST_VSOCK CONFIG_VHOST_SCSI CONFIG_VHOST_VDPA CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_MMIO CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_VIRTIO_GPU CONFIG_VIRTIO_FS CONFIG_VIRTIO_CONSOLE CONFIG_VIRTIO_INPUT CONFIG_RPMSG_VIRTIO CONFIG_REMOTEPROC CONFIG_REMOTEPROC_CDEV CONFIG_XEN CONFIG_XENFS CONFIG_XEN_VIRTIO CONFIG_HYPERV CONFIG_VBOXGUEST CONFIG_VMWARE_BALLOON CONFIG_VMWARE_VMCI CONFIG_VMWARE_PVSCSI CONFIG_DRM_I915_GVT CONFIG_DRM_I915_GVT_KVMGT; do',
    '\t\tif grep -Eq "^${symbol}=[ym]$" .config; then',
    '\t\t\techo "Unexpected enabled kernel option after oldconfig: ${symbol}" >&2',
    '\t\t\texit 1',
    '\t\tfi',
    '\tdone',
    '\tfor symbol in $(grep -oE "^CONFIG_NET_VENDOR_[A-Z0-9_]+=[ym]$" .config | cut -d= -f1); do',
    '\t\techo "Unexpected enabled Ethernet vendor after olddefconfig: $symbol" >&2',
    '\t\texit 1',
    '\tdone',
    '\tfor symbol in $(grep -oE "^CONFIG_WLAN_VENDOR_[A-Z0-9_]+=[ym]$" .config | cut -d= -f1); do',
    '\t\tif [ "$symbol" != CONFIG_WLAN_VENDOR_INTEL ]; then',
    '\t\t\techo "Unexpected enabled Wi-Fi vendor after olddefconfig: $symbol" >&2',
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
    export XBPS_CCACHE=yes
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
