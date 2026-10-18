#!/bin/sh
set -eu

# Scan tracked text dumps only; never walk Git objects or build caches.
python3 - <<'PY'
import pathlib
import re
import subprocess
import sys

raw = subprocess.check_output(["git", "ls-files", "-z", "--", "*.txt"])
paths = [pathlib.Path(item.decode()) for item in raw.split(b"\0") if item]
patterns = {
    "hardware UUID": re.compile(r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b", re.I),
    "MAC address": re.compile(r"\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b", re.I),
    "IPv4 address": re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
    "email address": re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I),
    "SSID field": re.compile(r"\bSSID\s*[:=]", re.I),
}
serial = re.compile(r"^\s*(?:System )?Serial Number:\s*(.*?)\s*$", re.I)
safe_serial_values = {"", "[redacted]", "to be filled by o.e.m.", "not specified", "none", "n/a"}
failures = []
for path in paths:
    try:
        lines = path.read_text(errors="strict").splitlines()
    except (UnicodeError, OSError) as exc:
        failures.append(f"{path}: cannot inspect text file ({exc})")
        continue
    for number, line in enumerate(lines, 1):
        for name, pattern in patterns.items():
            for match in pattern.finditer(line):
                value = match.group(0)
                if name == "IPv4 address":
                    octets = [int(part) for part in value.split(".")]
                    if any(part > 255 for part in octets):
                        continue
                    # Kernel/config text can mention all-zero wildcard addresses;
                    # these are not a machine's assigned address.
                    if value in {"0.0.0.0", "255.255.255.255"}:
                        continue
                failures.append(f"{path}:{number}: possible {name}")
        match = serial.match(line)
        if match and match.group(1).strip().lower() not in safe_serial_values:
            failures.append(f"{path}:{number}: unredacted hardware serial number")

if failures:
    print("Potentially sensitive identifiers remain in tracked .txt files:", file=sys.stderr)
    print("\n".join(sorted(set(failures))), file=sys.stderr)
    raise SystemExit(1)
print(f"Privacy scan passed for {len(paths)} tracked .txt files.")
PY
