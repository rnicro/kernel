#!/usr/bin/env python3
"""Check template kernelrelease mapping for mainline, stable, and RC versions."""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent
HELPER = ROOT / "fix-kernel-release-version.py"
FIXTURE = r'''pkgname=linux7.2
version=7.2.11
revision=1
_kernver="${version/rc/0-rc}_${revision}"
do_configure() {
    make ${makejobs} ARCH=$arch ${_cross} oldconfig
    sed -i -e 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="_${revision}"/' .config
}
'''

def expected_release(template: str, version: str, revision: str) -> str:
    match = re.search(r'case "\$version" in\n.*?\n\s*esac', template, re.S)
    if not match:
        raise SystemExit("Kernel version normalization case was not installed")
    script = "\n".join((
        'version="$1"; revision="$2"; _kernver="${version/rc/0-rc}_${revision}";',
        match.group(0),
        'printf "%s" "$_kernver"',
    ))
    result = subprocess.run(["bash", "-c", script, "test", version, revision],
                            check=True, capture_output=True, text=True)
    return result.stdout

def main() -> None:
    with tempfile.TemporaryDirectory(prefix="kernel-release-version-test-") as tmp:
        path = pathlib.Path(tmp) / "template"
        path.write_text(FIXTURE)
        subprocess.run([sys.executable, str(HELPER), str(path)], check=True)
        first = path.read_text()
        subprocess.run([sys.executable, str(HELPER), str(path)], check=True)
        if path.read_text() != first:
            raise SystemExit("Kernel release version fix is not idempotent")
        subprocess.run(["bash", "-n", str(path)], check=True)
        if "actual_kernver=" not in first or "make ${makejobs}" not in first:
            raise SystemExit("Early kernelrelease consistency check is missing")
        cases = {
            ("7.3", "1"): "7.3.0_1",
            ("7.2.11", "2"): "7.2.11_2",
            ("7.3-rc1", "1"): "7.3-0-rc1_1",
            ("6.12.55", "3"): "6.12.55_3",
        }
        for (version, revision), expected in cases.items():
            actual = expected_release(first, version, revision)
            if actual != expected:
                raise SystemExit(f"{version}_{revision}: got {actual}, expected {expected}")
    print("kernel release version tests passed")

if __name__ == "__main__":
    main()
