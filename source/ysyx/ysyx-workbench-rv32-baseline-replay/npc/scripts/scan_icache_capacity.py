#!/usr/bin/env python3
"""Functional trace screening; reports misses, never CPU cycles or IPC.

Online policies see only the current access. OPT alone reads future accesses;
it is an offline bound for the same set mapping and mandatory allocation.
Consecutive accesses to a line are compressed with their multiplicity retained:
the first access can miss, but following accesses must still promote RRIP state.
"""
import argparse
from array import array
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import struct


POLICIES = ("fifo", "lru", "srrip", "insert3", "brrip", "opt")


def read_program_counters(path):
    """Accept the RTL CSV trace or NEMU's versioned little-endian RLE trace."""
    with path.open("rb") as stream:
        magic = stream.read(8)
        stream.seek(0)
        if magic != b"NPCPCTR1":
            return array("Q", (int(row.split(b",")[0], 16) for row in stream
                               if row.strip()))
        header = stream.read(32)
        if len(header) != 32:
            raise ValueError("truncated NEMU header")
        _, version, address_bytes, access_count, run_count = struct.unpack("<8sIIQQ", header)
        if version != 1 or address_bytes not in (4, 8):
            raise ValueError("unsupported NEMU trace format")
        counters = array("Q")
        for _ in range(run_count):
            data = stream.read(16)
            if len(data) != 16:
                raise ValueError("truncated NEMU run")
            first, count, stride = struct.unpack("<QIi", data)
            if count == 0 or first + (count - 1) * stride < 0:
                raise ValueError("invalid NEMU run")
            counters.extend(first + index * stride for index in range(count))
        if len(counters) != access_count or stream.read(1):
            raise ValueError("NEMU trace count/length mismatch")
        return counters


def line_runs(counters, line_bytes):
    lines, counts = array("Q"), array("Q")
    for pc in counters:
        line = pc // line_bytes
        if lines and lines[-1] == line:
            counts[-1] += 1
        else:
            lines.append(line)
            counts.append(1)
    return lines, counts


def next_uses(lines):
    positions = {}
    following = array("Q", [len(lines)]) * len(lines)
    for index in range(len(lines) - 1, -1, -1):
        following[index] = positions.get(lines[index], len(lines))
        positions[lines[index]] = index
    return following


@dataclass
class Entry:
    line: int
    inserted: int
    last: int
    rrpv: int
    following: int = 0


def simulate(lines, counts, capacity_bytes, line_bytes, ways, policy, following=None):
    for value in (capacity_bytes, line_bytes, ways):
        if value <= 0 or value & (value - 1):
            raise ValueError("cache geometry must use positive powers of two")
    if capacity_bytes < line_bytes * ways or policy not in POLICIES:
        raise ValueError("invalid cache geometry or policy")
    if len(lines) != len(counts) or any(count == 0 for count in counts):
        raise ValueError("invalid line run lengths")
    if policy == "opt" and following is None:
        following = next_uses(lines)
    set_count = capacity_bytes // line_bytes // ways
    sets = [[] for _ in range(set_count)]
    misses = 0
    rrip = policy in ("srrip", "insert3", "brrip")
    for step, line in enumerate(lines):
        entries = sets[line % set_count]
        hit = next((entry for entry in entries if entry.line == line), None)
        if hit is not None:
            hit.last = step
            if rrip:
                hit.rrpv = 0
            if policy == "opt":
                hit.following = following[step]
            continue
        misses += 1
        if len(entries) == ways:
            if rrip:
                age = 3 - max(entry.rrpv for entry in entries)
                for entry in entries:
                    entry.rrpv += age
                # Stable list order gives deterministic ties; not an RTL way-order claim.
                victim = next(entry for entry in entries if entry.rrpv == 3)
            elif policy == "opt":
                victim = max(entries, key=lambda entry: entry.following)
            else:
                victim = min(entries, key=lambda entry:
                             entry.last if policy == "lru" else entry.inserted)
            entries.remove(victim)
        insert_rrpv = 2 if policy == "srrip" or (policy == "brrip" and misses % 32 == 0) else 3
        if counts[step] > 1 and rrip:
            insert_rrpv = 0
        entries.append(Entry(line, step, step, insert_rrpv,
                             following[step] if policy == "opt" else 0))
    return misses


def scan(path, capacities, line_sizes, way_counts, policies):
    counters = read_program_counters(path)
    records = []
    for line_bytes in line_sizes:
        lines, counts = line_runs(counters, line_bytes)
        following = next_uses(lines)
        for capacity in capacities:
            for ways in way_counts:
                if capacity < line_bytes * ways:
                    continue
                for policy in (("fifo", "opt") if ways == 1 else policies):
                    misses = simulate(lines, counts, capacity, line_bytes, ways, policy,
                                      following if policy == "opt" else None)
                    records.append({"capacity_bytes": capacity, "line_bytes": line_bytes,
                                    "ways": ways, "policy": policy, "misses": misses,
                                    "accesses": len(counters), "unique_lines": len(set(lines)),
                                    "line_runs": len(lines), "misses_per_kinst":
                                    1000 * misses / len(counters) if counters else 0,
                                    "demand_refill_bytes": misses * line_bytes})
    return {"trace": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "records": records}


def integers(text):
    return [int(value) for value in text.split(",")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--capacities", type=integers, default=integers("256,512,1024,2048,4096,8192,16384"))
    parser.add_argument("--line-sizes", type=integers, default=[16, 32])
    parser.add_argument("--ways", type=integers, default=[1, 2, 4])
    args = parser.parse_args()
    # Reserve the result before expensive work. Never overwrite an earlier experiment.
    with args.output.open("x") as stream:
        result = {"schema": 1, "model": "cold, mandatory-allocate, retired-path-only",
                  "not_modeled": ["wrong paths", "fill timing", "prefetch", "bus arbitration",
                                  "FENCE.I/invalidation", "CPU cycles/IPC", "physical area/frequency"],
                  "opt": "future-aware bound, never an implementable candidate",
                  "online_ties": "oldest remaining insertion; not bit-exact RTL replacement",
                  "model_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  "cases": []}
        for path in args.trace:
            print(f"Screening {path}", flush=True)
            result["cases"].append(scan(path, args.capacities, args.line_sizes, args.ways, POLICIES))
        json.dump(result, stream, indent=2)
        stream.write("\n")


if __name__ == "__main__":
    main()
