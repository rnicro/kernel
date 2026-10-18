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

# Preserve Void's full maintained config and drivers. Tune compiler scheduling
# for Skylake without enabling newer instructions or using the runner's CPU.
python3 - "$pkg" <<'PY'
import pathlib
import sys

pkg = sys.argv[1]
path = pathlib.Path("srcpkgs") / pkg / "template"
text = path.read_text()
old = 'export KCFLAGS="-ffile-prefix-map=${wrksrc}=."'
new = 'export KCFLAGS="-ffile-prefix-map=${wrksrc}=. -mtune=skylake"'
if text.count(old) == 1:
    text = text.replace(old, new, 1)
else:
    anchor = "\\texport LDFLAGS=\\n"
    addition = '\\texport KCFLAGS="${KCFLAGS} -mtune=skylake"\\n'
    if text.count(anchor) != 1 or "mtune=skylake" in text:
        raise SystemExit("Kernel template changed: could not safely apply Skylake tuning")
    text = text.replace(anchor, anchor + addition, 1)
path.write_text(text)
PY

./xbps-src binary-bootstrap
./xbps-src -j"$BUILD_JOBS" pkg "$pkg"

mkdir -p /workspace/artifacts
find hostdir/binpkgs -type f -name "$pkg-*.xbps" ! -name "*-dbg-*.xbps" \
  -exec cp -v {} /workspace/artifacts/ \;
test -n "$(find /workspace/artifacts -maxdepth 1 -type f -name '*.xbps' -print -quit)"
cp "srcpkgs/$pkg/template" /workspace/artifacts/kernel-template-used.txt
printf 'Package: %s\nCompiler tuning: -mtune=skylake\n' "$pkg" > /workspace/artifacts/build-info.txt
