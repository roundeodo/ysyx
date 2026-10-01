#!/usr/bin/env python3
"""Check the selected I-cache policy and RV64 cache/AXI contract independently."""

import argparse
import hashlib
import json
from pathlib import Path
import random
import resource
import subprocess

NPC = Path(__file__).resolve().parents[1]


def run(command, log):
    with log.open("w") as stream:
        result = subprocess.run(list(map(str, command)), cwd=NPC,
                                stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text()[-12000:])
        raise SystemExit(result.returncode)


def replacement_events(capacity, ways, line_bytes, policy):
    """Whole-cache oracle: select invalid first, age one step at a time on miss."""
    sets = capacity // (ways * line_bytes)
    tags = [[None] * ways for _ in range(sets)]
    ages = [[3] * ways for _ in range(sets)]
    next_way = [0] * sets
    previous_line = None
    rng = random.Random(813)
    # Fill one set, revisit after a line change, scan past capacity, and repeat hits.
    blocks = [way * sets for way in range(ways)]
    blocks += [0, 0, sets, 0, ways * sets, 0, (ways + 1) * sets]
    for index in range(5000):
        block = (rng.randrange(ways + 2) * sets + index % sets
                 if index % 97 < 60 else rng.randrange(ways * sets * 4))
        blocks += [block] * rng.randrange(1, 5)
    events = []
    for block in blocks:
        address = 0x80000000 + block * line_bytes
        line = address // line_bytes
        set_index = line % sets
        miss = line not in tags[set_index]
        if miss:
            if None in tags[set_index]:
                way = tags[set_index].index(None)
            elif policy == 0:
                way = next_way[set_index]
            else:
                while 3 not in ages[set_index]:
                    ages[set_index] = [age + 1 for age in ages[set_index]]
                way = ages[set_index].index(3)
            tags[set_index][way] = line
            ages[set_index][way] = 2
            next_way[set_index] = (way + 1) % ways
        else:
            way = tags[set_index].index(line)
            if line != previous_line:
                ages[set_index][way] = 0
        previous_line = line
        events.append(f"{address:x} {int(miss)} {way}\n")
    return "".join(events)


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", choices=("cache", "replacement"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reference-rtl", type=Path,
                        help="Optional source policy module to replay against the same oracle")
    parser.add_argument("defines", nargs="+")
    args = parser.parse_args()
    defines = dict(item.removeprefix("+define+").split("=", 1)
                   for item in args.defines if item.startswith("+define+") and "=" in item)
    policy = int(defines["YSYX_ICACHE_REPLACEMENT_POLICY"])
    if args.test == "replacement" and policy == 0:
        print("SKIP segmented RRIP module: policy 0 uses the existing cache-local round-robin state")
        return
    output = args.output.resolve() / args.test
    output.mkdir(parents=True, exist_ok=True)
    rtl = NPC / "vsrc/riscv"
    packages = [rtl / "common" / name for name in (
        "riscv_config_pkg.sv", "riscv_addr_map_pkg.sv", "riscv_axi4_pkg.sv", "riscv_pkg.sv")]
    if args.test == "cache":
        names = ("pma", "icache_tag_array", "icache_data_array", "icache_miss_unit",
                 "icache_replacement", "icache", "icache_axi")
        top = "riscv_icache_contract_tb"
        options = []
    else:
        names = ("icache_replacement",)
        top = "riscv_icache_replacement_tb"
        events = replacement_events(int(defines["YSYX_ICACHE_CAPACITY_BYTES"]),
                                    int(defines["YSYX_ICACHE_WAY_COUNT"]),
                                    int(defines["YSYX_ICACHE_LINE_BYTES"]), policy)
        (output / "events.txt").write_text(events)
        options = [f"+events={output / 'events.txt'}"]
    modules = [rtl / "core/frontend" / f"riscv_{name}.sv" for name in names]
    testbench = NPC / "tests/rtl" / f"{top}.sv"
    sources = packages + modules + [testbench]
    runs = [(output, sources)]
    if args.reference_rtl:
        if args.test != "replacement":
            parser.error("--reference-rtl is only valid for replacement tests")
        reference = args.reference_rtl.read_text().replace("riscv32_", "riscv_")
        for old, new in (("read_set_i", "read_set_index_i"),
                         ("read_victim_o", "read_victim_way_index_o"),
                         ("allocate_way_i", "allocate_way_index_i")):
            reference = reference.replace(old, new)
        folder = output / "reference"
        folder.mkdir(exist_ok=True)
        path = folder / "riscv_icache_replacement.sv"
        path.write_text(reference)
        runs.append((folder, packages + [path, testbench]))
    manifest = {"test": args.test, "runs": [], "driver_sha256":
                hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    if args.test == "replacement":
        manifest["events_sha256"] = hashlib.sha256(events.encode()).hexdigest()
        manifest["decisions_per_run"] = 2 * len(events.splitlines())
    if args.reference_rtl:
        manifest["reference_source"] = str(args.reference_rtl.resolve())
        manifest["reference_sha256"] = hashlib.sha256(args.reference_rtl.read_bytes()).hexdigest()
    for folder, run_sources in runs:
        command = ["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", "-j", "2",
                   "-MAKEFLAGS", "OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0",
                   *args.defines, "--top-module", top, "--Mdir", folder / "obj", *run_sources]
        run(command, folder / "build.log")
        execute = [folder / "obj" / f"V{top}", *options]
        run(execute, folder / "run.log")
        print((folder / "run.log").read_text())
        manifest["runs"].append({
            "status": "passed", "build": list(map(str, command)), "run": list(map(str, execute)),
            "sources": {str(p.relative_to(NPC)) if p.is_relative_to(NPC) else str(p):
                        hashlib.sha256(p.read_bytes()).hexdigest() for p in run_sources},
        })
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
