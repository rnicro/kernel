#!/bin/sh
set -eu

: "${KERNEL_PACKAGE:=}"
: "${BUILD_JOBS:=4}"
: "${VOID_REPO:=https://repo-de.voidlinux.org}"

# Avoid the broken default mirror endpoint seen in CI while keeping HTTPS and
# XBPS signature verification enabled. Retry transient repository failures.
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
retry xbps-install -y git base-devel xtools python3 util-linux shadow

git clone --depth=1 https://github.com/void-linux/void-packages.git
cd void-packages

# Reuse verified runner caches for downloaded source archives and XBPS packages.
# Keep build outputs/chroots out of Actions cache; they are large and host-specific.
mkdir -p /workspace/cache/sources /workspace/cache/repocache-x86_64-musl hostdir
rm -rf hostdir/sources hostdir/repocache-x86_64-musl
ln -s /workspace/cache/sources hostdir/sources
ln -s /workspace/cache/repocache-x86_64-musl hostdir/repocache-x86_64-musl

# Select the newest kernel series present in Void's packaging repository.
if [ -z "$KERNEL_PACKAGE" ]; then
    KERNEL_PACKAGE="$(python3 - <<'PY'
import pathlib
import re
versions = []
for path in pathlib.Path("srcpkgs").glob("linux*"):
    if path.is_dir() and (path / "template").is_file():
        match = re.fullmatch(r"linux(\d+)\.(\d+)", path.name)
        if match:
            versions.append((int(match.group(1)), int(match.group(2)), path.name))
if not versions:
    raise SystemExit("No versioned Linux kernel templates found in Void Packages")
print(max(versions)[2])
PY
)"
fi

pkg="$KERNEL_PACKAGE"
template="srcpkgs/$pkg/template"
config="srcpkgs/$pkg/files/x86_64-dotconfig"
test -f "$template"
test -f "$config"
echo "Selected Void kernel package: $KERNEL_PACKAGE"

# Skylake tuning without raising the x86-64 ISA baseline.
python3 - "$template" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=."'
new = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=. -mtune=skylake"'
if old not in text:
    if "-mtune=skylake" in text:
        raise SystemExit("Skylake tuning already present; refusing duplicate")
    raise SystemExit("Kernel template KCFLAGS assignment changed; refusing unsafe patch")
path.write_text(text.replace(old, new, 1))
PY

# xbps-src explicitly refuses to run as root. Create a disposable unprivileged
# builder, grant it only the workspace paths required for compilation, and run
# both bootstrap and package compilation as that user.
if ! id builder >/dev/null 2>&1; then
    useradd -m -U -s /bin/sh builder
fi
chown -R builder:builder /workspace/void-packages /workspace/cache/sources /workspace/cache/repocache-x86_64-musl
mkdir -p /workspace/artifacts
chown builder:builder /workspace/artifacts

su -s /bin/sh builder -c "
    set -eu
    cd /workspace/void-packages
    ./xbps-src binary-bootstrap
    export XBPS_CHROOT_CMD=ethereal
    export XBPS_ALLOW_CHROOT_BREAKOUT=yes
    ./xbps-src -j'$BUILD_JOBS' pkg '$KERNEL_PACKAGE'
"

# Publish installable packages only; omit debug packages and build metadata.
find hostdir/binpkgs -type f -name "$KERNEL_PACKAGE-*.xbps" ! -name "*-dbg-*.xbps" -print0 \
    | xargs -0 -r cp -v -t /workspace/artifacts
test -n "$(find /workspace/artifacts -maxdepth 1 -type f -name '*.xbps' -print -quit)"
