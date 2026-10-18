#!/bin/sh
set -eu

: "${KERNEL_PACKAGE:=}"
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
retry xbps-install -y git base-devel xtools python3 util-linux shadow

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
}
trap sync_caches EXIT HUP INT TERM

# Select the newest stable kernel series available as a Void package template.
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
test -f "$template" || { echo "Missing kernel template: $template" >&2; exit 1; }
test -f "$config" || { echo "Missing x86_64 kernel config: $config" >&2; exit 1; }
echo "Selected Void kernel package: $KERNEL_PACKAGE"

# Tune instruction scheduling for Skylake without raising the x86-64 ISA baseline.
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

# xbps-src must run unprivileged. Bootstrap and package compilation use the
# same builder identity; ethereal mode is selected only after bootstrap.
if ! id builder >/dev/null 2>&1; then
    useradd -m -U -s /bin/sh builder
fi
chown -R builder:builder /workspace/void-packages
mkdir -p /workspace/artifacts
chown builder:builder /workspace/artifacts

su -s /bin/sh builder -c "
    set -eu
    cd /workspace/void-packages
    ./xbps-src -A x86_64-musl binary-bootstrap
    test -x masterdir/usr/bin/xbps-query || {
        echo binary-bootstrap_returned_without_installing_xbps-query_in_masterdir >&2
        exit 1
    }
    export XBPS_CHROOT_CMD=ethereal
    export XBPS_ALLOW_CHROOT_BREAKOUT=yes
    ./xbps-src -A x86_64-musl -j'$BUILD_JOBS' pkg '$KERNEL_PACKAGE'
"

# Publish only the requested installable package family, excluding debug builds.
find hostdir/binpkgs -type f -name "$KERNEL_PACKAGE-*.xbps" ! -name "*-dbg-*.xbps" -print0 \
    | xargs -0 -r cp -v -t /workspace/artifacts
if ! find /workspace/artifacts -maxdepth 1 -type f -name '*.xbps' -print -quit | grep -q .; then
    echo "Build finished without producing installable .xbps packages" >&2
    exit 1
fi
