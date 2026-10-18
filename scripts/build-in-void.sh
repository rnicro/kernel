#!/bin/sh
set -eux

: "${KERNEL_PACKAGE:=linux6.18}"
: "${BUILD_JOBS:=4}"

xbps-install -Syu xbps
xbps-install -y git base-devel xtools python3

git clone --depth=1 https://github.com/void-linux/void-packages.git
cd void-packages

pkg="$KERNEL_PACKAGE"
test -f "srcpkgs/$pkg/template"
test -f "srcpkgs/$pkg/files/x86_64-dotconfig"

# Start with Void's maintained configuration, then apply the device-specific fragment.
cp "srcpkgs/$pkg/files/x86_64-dotconfig" \
   "srcpkgs/$pkg/files/x86_64-dotconfig-custom"
install -m 0644 /workspace/config/x86_64-dotconfig-fragment \
   "srcpkgs/$pkg/files/x86_64-dotconfig-fragment"

python3 - "$pkg" <<'PY'
import pathlib
import sys

pkg = sys.argv[1]
path = pathlib.Path("srcpkgs") / pkg / "template"
text = path.read_text()
anchor = "\t# Always use our revision to CONFIG_LOCALVERSION to match our pkg version.\n"
addition = (
    "\t# Merge the device-specific CPU tuning fragment.\n"
    "\tif [ -f \"${FILESDIR}/x86_64-dotconfig-fragment\" ]; then\n"
    "\t\tscripts/kconfig/merge_config.sh -m .config \"${FILESDIR}/x86_64-dotconfig-fragment\"\n"
    "\t\tmake ${makejobs} ARCH=$arch ${_cross} olddefconfig\n"
    "\tfi\n\n"
)
if text.count(anchor) != 1:
    raise SystemExit("Kernel template changed: could not safely locate config insertion point")
path.write_text(text.replace(anchor, addition + anchor, 1))
PY

./xbps-src binary-bootstrap
./xbps-src -j"$BUILD_JOBS" pkg "$pkg"

mkdir -p /workspace/artifacts
find hostdir/binpkgs -type f -name "$pkg-*.xbps" ! -name "*-dbg-*.xbps" \
  -exec cp -v {} /workspace/artifacts/ \;
test -n "$(find /workspace/artifacts -maxdepth 1 -type f -name '*.xbps' -print -quit)"
cp "srcpkgs/$pkg/template" /workspace/artifacts/kernel-template-used.txt
printf 'Package: %s\nConfig fragment: Skylake\n' "$pkg" > /workspace/artifacts/build-info.txt
