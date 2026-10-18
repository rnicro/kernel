#!/bin/sh
set -eu

: "${KERNEL_PACKAGE:=linux7.2}"
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
retry xbps-install -y git base-devel xtools python3 util-linux shadow sudo

git clone --depth=1 https://github.com/void-linux/void-packages.git
cd void-packages

pkg="$KERNEL_PACKAGE"
template="srcpkgs/$pkg/template"
config="srcpkgs/$pkg/files/x86_64-dotconfig"
test -f "$template"
test -f "$config"

# xbps-src refuses to run as root. Give it a dedicated unprivileged builder
# with passwordless sudo only inside this disposable CI container.
groupadd -g 1000 xbuilder
useradd -m -u 1000 -g xbuilder -s /bin/sh xbuilder
mkdir -p /etc/sudoers.d
printf 'xbuilder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/xbuilder
chmod 0440 /etc/sudoers.d/xbuilder
chmod 0777 /workspace/artifacts
chown -R xbuilder:xbuilder /workspace/void-packages

# Apply only a safe scheduling hint for the target Skylake CPU. Do not use
# -march=native or enable instructions that the target CPU may not support.
python3 - "$template" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=."'
new = 'export KCFLAGS="-ffile-prefix-map=$wrksrc=. -mtune=skylake"'
if text.count(old) != 1:
    raise SystemExit(
        "Kernel template changed: expected exactly one KCFLAGS assignment; "
        "refusing to silently drop target tuning"
    )
path.write_text(text.replace(old, new, 1))
PY

su -m -s /bin/sh xbuilder -c 'cd /workspace/void-packages && ./xbps-src binary-bootstrap'
su -m -s /bin/sh xbuilder -c 'cd /workspace/void-packages && ./xbps-src -j"$BUILD_JOBS" pkg "$KERNEL_PACKAGE"'

# Keep the installable kernel and headers packages; omit debug packages and
# build metadata from the published artifact.
su -m -s /bin/sh xbuilder -c 'cd /workspace/void-packages && find hostdir/binpkgs -type f -name "$KERNEL_PACKAGE-*.xbps" ! -name "*-dbg-*.xbps" -exec cp -v {} /workspace/artifacts/ \\;'
test -n "$(find /workspace/artifacts -maxdepth 1 -type f -name '*.xbps' -print -quit)"
