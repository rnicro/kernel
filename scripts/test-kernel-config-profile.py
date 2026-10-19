#!/usr/bin/env python3
"""Regression-test the laptop kernel config profile without a kernel build."""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent
TRANSFORMER = ROOT / "optimize-kernel-config.py"
SEED = """\
CONFIG_ETHERNET=y
CONFIG_R8169=m
CONFIG_NET_VENDOR_BROADCOM=y
CONFIG_NET_VENDOR_REALTEK=y
CONFIG_NET_VENDOR_INTEL=y
CONFIG_SCSI_BNX2_ISCSI=m
CONFIG_SCSI_BNX2X_FCOE=m
CONFIG_SCSI_CXGB3_ISCSI=m
CONFIG_SCSI_CXGB4_ISCSI=m
CONFIG_WLAN_VENDOR_INTEL=y
CONFIG_IWLWIFI=m
CONFIG_DRM_I915=m
CONFIG_EXT4_FS=y
CONFIG_MISC_RTSX_PCI=m
"""

DISABLED = (
    "CONFIG_ETHERNET",
    "CONFIG_R8169",
    "CONFIG_NET_VENDOR_BROADCOM",
    "CONFIG_NET_VENDOR_REALTEK",
    "CONFIG_NET_VENDOR_INTEL",
    "CONFIG_SCSI_BNX2_ISCSI",
    "CONFIG_SCSI_BNX2X_FCOE",
    "CONFIG_SCSI_CXGB3_ISCSI",
    "CONFIG_SCSI_CXGB4_ISCSI",
)

def main() -> None:
    with tempfile.TemporaryDirectory(prefix="kernel-config-test-") as tmp:
        config = pathlib.Path(tmp) / "x86_64-dotconfig"
        config.write_text(SEED)
        subprocess.run([sys.executable, str(TRANSFORMER), str(config)], check=True)
        first = config.read_text()
        subprocess.run([sys.executable, str(TRANSFORMER), str(config)], check=True)
        second = config.read_text()
        if first != second:
            raise SystemExit("Kernel config transformer is not idempotent")
        for symbol in DISABLED:
            lines = [line for line in first.splitlines()
                     if re.match(rf"^(?:# )?{re.escape(symbol)}(?:=| is not set$)", line)]
            expected = f"# {symbol} is not set"
            if lines != [expected]:
                raise SystemExit(f"{symbol} not disabled exactly once: {lines}")
        for setting in ("CONFIG_WLAN_VENDOR_INTEL=y", "CONFIG_IWLWIFI=m",
                        "CONFIG_DRM_I915=m", "CONFIG_EXT4_FS=y",
                        "CONFIG_MISC_RTSX_PCI=m"):
            if setting not in first.splitlines():
                raise SystemExit(f"Required laptop setting was not preserved: {setting}")
    print("kernel config profile tests passed")

if __name__ == "__main__":
    main()
