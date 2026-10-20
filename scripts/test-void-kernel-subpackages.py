#!/usr/bin/env python3
"""Regression tests for generated Void kernel subpackage template layout."""
from __future__ import annotations

import importlib.util
import pathlib
import tempfile

SCRIPT = pathlib.Path(__file__).with_name("ensure-void-kernel-subpackages.py")
SPEC = importlib.util.spec_from_file_location("ensure_void_kernel_subpackages", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("Could not load kernel subpackage helper")
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


def main() -> None:
    # Missing aliases are created and repeated invocations are idempotent.
    with tempfile.TemporaryDirectory(prefix="kernel-subpackages-test-") as tmp:
        root = pathlib.Path(tmp)
        main_package = root / "srcpkgs" / "linux7.3"
        main_package.mkdir(parents=True)
        (main_package / "template").write_text("pkgname=linux7.3\n")

        HELPER.ensure_subpackage_links(root, "linux7.3")
        for suffix in ("headers", "dbg"):
            alias = root / "srcpkgs" / f"linux7.3-{suffix}"
            if not alias.is_symlink() or alias.resolve() != main_package.resolve():
                raise SystemExit(f"Subpackage alias not created correctly: {alias}")
        HELPER.ensure_subpackage_links(root, "linux7.3")

    # A valid real subpackage directory should be preserved.
    with tempfile.TemporaryDirectory(prefix="kernel-subpackages-real-") as tmp:
        root = pathlib.Path(tmp)
        main_package = root / "srcpkgs" / "linux7.3"
        main_package.mkdir(parents=True)
        (main_package / "template").write_text("pkgname=linux7.3\n")
        headers = root / "srcpkgs" / "linux7.3-headers"
        headers.mkdir()
        (headers / "template").write_text("pkgname=linux7.3-headers\n")

        HELPER.ensure_subpackage_links(root, "linux7.3")
        if headers.is_symlink() or (headers / "template").read_text() != "pkgname=linux7.3-headers\n":
            raise SystemExit("Existing real subpackage template was changed")
        if not (root / "srcpkgs" / "linux7.3-dbg").is_symlink():
            raise SystemExit("Missing debug subpackage alias")

    # A broken symlink must fail fast instead of failing much later in xbps-src.
    with tempfile.TemporaryDirectory(prefix="kernel-subpackages-conflict-") as tmp:
        root = pathlib.Path(tmp)
        main_package = root / "srcpkgs" / "linux7.3"
        main_package.mkdir(parents=True)
        (main_package / "template").write_text("pkgname=linux7.3\n")
        (root / "srcpkgs" / "linux7.3-dbg").symlink_to("missing-target")
        try:
            HELPER.ensure_subpackage_links(root, "linux7.3")
        except SystemExit as exc:
            if "Broken kernel subpackage link" not in str(exc):
                raise
        else:
            raise SystemExit("Broken subpackage symlink was not rejected")

    print("kernel subpackage layout tests passed")


if __name__ == "__main__":
    main()
