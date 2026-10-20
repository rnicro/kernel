#!/usr/bin/env python3
"""Ensure Void's generated kernel template exposes its declared subpackages."""
from __future__ import annotations

import pathlib
import sys

SUBPACKAGES = ("headers", "dbg")


def ensure_subpackage_links(root: pathlib.Path, package: str) -> None:
    if not package or package in {".", ".."} or pathlib.Path(package).name != package:
        raise SystemExit(f"Invalid kernel package name: {package!r}")

    srcpkgs = root / "srcpkgs"
    package_dir = srcpkgs / package
    if not (package_dir / "template").is_file():
        raise SystemExit(f"Missing kernel template: {package_dir / 'template'}")
    package_dir = package_dir.resolve()

    for suffix in SUBPACKAGES:
        link = srcpkgs / f"{package}-{suffix}"
        if link.is_symlink():
            try:
                target = link.resolve(strict=True)
            except (OSError, RuntimeError) as exc:
                raise SystemExit(f"Broken kernel subpackage link: {link}: {exc}") from exc
            if target != package_dir:
                raise SystemExit(
                    f"Unexpected kernel subpackage link: {link} -> {target}; "
                    f"expected {package_dir}"
                )
        elif link.exists():
            if not link.is_dir() or not (link / "template").is_file():
                raise SystemExit(
                    f"Kernel subpackage path exists without a template: {link}"
                )
        else:
            link.symlink_to(package, target_is_directory=True)
        if not (link / "template").is_file():
            raise SystemExit(f"Kernel subpackage template is unavailable: {link / 'template'}")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: ensure-void-kernel-subpackages.py VOID_PACKAGES_ROOT PACKAGE")
    ensure_subpackage_links(pathlib.Path(sys.argv[1]), sys.argv[2])


if __name__ == "__main__":
    main()
