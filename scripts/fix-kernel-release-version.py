#!/usr/bin/env python3
"""Normalize Void's kernel template module-directory version to Linux KERNELRELEASE."""
from __future__ import annotations

import pathlib
import re
import sys

ASSIGNMENT = '_kernver="${version/rc/0-rc}_${revision}"'
RULE = '''case "$version" in
\t*-rc*) ;;
\t*.*.*) ;;
\t*.*) _kernver="${version}.0_${revision}" ;;
esac'''
CHECK = '\tactual_kernver="$(make ${makejobs} ARCH=$arch ${_cross} -s kernelrelease)"'

def patch(path: pathlib.Path) -> None:
    text = path.read_text()

    if RULE not in text:
        if ASSIGNMENT not in text:
            raise SystemExit("Kernel template _kernver assignment changed; refusing unsafe patch")
        text = text.replace(ASSIGNMENT, ASSIGNMENT + "\n# Mainline X.Y tarballs build as KERNELRELEASE X.Y.0; package version stays X.Y.\n" + RULE, 1)

    if CHECK not in text:
        matches = list(re.finditer(r'(?m)^[ \t]*sed -i -e .*CONFIG_LOCALVERSION.*\.config$', text))
        if len(matches) != 1:
            raise SystemExit("Could not find the package-localversion assignment for the kernelrelease check")
        verification = (
            "\n" + CHECK
            + '\n\tif [ "$actual_kernver" != "$_kernver" ]; then'
            + '\n\t\techo "Kernel release mismatch: template expects $_kernver, Kbuild reports $actual_kernver" >&2'
            + '\n\t\texit 1'
            + '\n\tfi'
        )
        text = text[:matches[0].end()] + verification + text[matches[0].end():]

    path.write_text(text)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: fix-kernel-release-version.py PATH_TO_TEMPLATE")
    patch(pathlib.Path(sys.argv[1]))
