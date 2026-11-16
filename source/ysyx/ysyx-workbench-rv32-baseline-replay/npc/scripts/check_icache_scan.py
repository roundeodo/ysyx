#!/usr/bin/env python3
"""Check OPT bounds and compare Python LRU with the existing independent C++ model."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from scan_icache_capacity import read_program_counters


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scan", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = json.loads(args.scan.read_text())
    checks = []
    with args.output.open("x") as output, tempfile.TemporaryDirectory() as directory:
        for case in result["cases"]:
            trace = Path(case["trace"])
            assert hashlib.sha256(trace.read_bytes()).hexdigest() == case["sha256"]
            # Convert CSV's extra columns, retaining every architectural access.
            raw = Path(directory) / "pc.txt"
            raw.write_text("".join(f"0x{pc:x}\n" for pc in read_program_counters(trace)))
            opt = {(row["capacity_bytes"], row["line_bytes"], row["ways"]): row["misses"]
                   for row in case["records"] if row["policy"] == "opt"}
            for row in case["records"]:
                geometry = (row["capacity_bytes"], row["line_bytes"], row["ways"])
                assert row["unique_lines"] <= opt[geometry] <= row["misses"] <= row["accesses"], row
                if row["policy"] != "lru" and not (row["policy"] == "fifo" and row["ways"] == 1):
                    continue
                command = [str(args.reference.resolve()), "--trace", str(raw),
                           "--capacity-bytes", str(geometry[0]), "--line-bytes", str(geometry[1]),
                           "--ways", str(geometry[2]), "--output-format", "json"]
                reference = json.loads(subprocess.check_output(command, text=True))
                assert reference["misses"] == row["misses"], (trace, row, reference)
                assert reference["accesses"] == row["accesses"], (trace, row, reference)
                checks.append({"case": trace.stem, "geometry": geometry, "misses": row["misses"]})
        json.dump({"passed": len(checks), "scan_sha256": hashlib.sha256(args.scan.read_bytes()).hexdigest(),
                   "reference_sha256": hashlib.sha256(args.reference.read_bytes()).hexdigest(),
                   "checks": checks}, output, indent=2)
        output.write("\n")
    print(f"PASS C++/Python LRU and bounds: {len(checks)} geometries")


if __name__ == "__main__":
    main()
