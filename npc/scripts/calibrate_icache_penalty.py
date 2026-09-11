#!/usr/bin/env python3

import argparse
import csv
import pathlib
import re
import subprocess
import sys
from dataclasses import asdict, dataclass


FLOAT_PATTERN = r"[0-9]+(?:\.[0-9]+)?"


@dataclass(frozen=True)
class CalibrationResult:
    line_bytes: int
    cache_capacity_bytes: int
    cache_way_count: int
    benchmark_scale: str
    benchmark_arch: str
    refill_transport: str
    lookup_count: int
    cache_hit_count: int
    cache_miss_count: int
    average_hit_response_latency_cycles: float
    average_critical_response_latency_cycles: float
    average_miss_penalty_cycles: float
    average_complete_refill_latency_cycles: float
    exact_amat_cycles: float
    measurement_window_cycles: int
    measurement_window_retired_instructions: int
    measurement_window_ipc: float


def parse_line_sizes(text: str) -> list[int]:
    line_sizes = [int(item, 0) for item in text.split(",") if item]
    if not line_sizes:
        raise ValueError("at least one I-cache line size is required")
    if len(set(line_sizes)) != len(line_sizes):
        raise ValueError("I-cache line sizes must not contain duplicates")
    for line_size in line_sizes:
        if line_size < 4 or line_size > 64 or line_size & (line_size - 1):
            raise ValueError(
                "I-cache line sizes must be powers of two between 4 and 64 bytes"
            )
    return line_sizes


def parse_single_match(pattern: str, output: str, label: str) -> re.Match[str]:
    matches = list(re.finditer(pattern, output, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {label}, found {len(matches)}")
    return matches[0]


def parse_calibration_output(
    output: str,
    line_bytes: int,
    cache_capacity_bytes: int,
    cache_way_count: int,
    benchmark_scale: str,
    benchmark_arch: str,
) -> CalibrationResult:
    counts = parse_single_match(
        r"lookups / cacheable hits / cacheable misses\s*:\s*"
        r"(\d+)\s*/\s*(\d+)\s*/\s*(\d+)",
        output,
        "I-cache lookup counter group",
    )
    hit_latency = parse_single_match(
        rf"average hit response latency\s*:\s*({FLOAT_PATTERN})\s+cycles",
        output,
        "average hit response latency",
    )
    critical_latency = parse_single_match(
        rf"average miss critical response latency\s*:\s*({FLOAT_PATTERN})\s+cycles",
        output,
        "average miss critical response latency",
    )
    miss_penalty = parse_single_match(
        rf"average miss penalty\s*:\s*({FLOAT_PATTERN})\s+cycles",
        output,
        "average miss penalty",
    )
    complete_refill_latency = parse_single_match(
        rf"average complete refill latency\s*:\s*({FLOAT_PATTERN})\s+cycles",
        output,
        "average complete refill latency",
    )
    measurement = parse_single_match(
        r"MicroBench PMU measurement window:\s*\n"
        r"\s*cycles\s*=\s*(\d+)\s*\n"
        r"\s*retired instructions\s*=\s*(\d+)\s*\n"
        rf"\s*IPC\s*=\s*({FLOAT_PATTERN})",
        output,
        "MicroBench PMU measurement window",
    )

    lookup_count = int(counts.group(1))
    cache_hit_count = int(counts.group(2))
    cache_miss_count = int(counts.group(3))
    average_hit_latency = float(hit_latency.group(1))
    average_critical_latency = float(critical_latency.group(1))
    average_penalty = float(miss_penalty.group(1))
    average_complete_latency = float(complete_refill_latency.group(1))
    measurement_cycles = int(measurement.group(1))
    measurement_instructions = int(measurement.group(2))
    measurement_ipc = measurement_instructions / measurement_cycles

    if cache_miss_count == 0:
        raise ValueError("calibration workload produced zero I-cache misses")
    if abs((average_critical_latency - average_hit_latency) - average_penalty) > 0.002:
        raise ValueError("reported miss penalty does not equal critical latency minus hit latency")

    exact_amat = average_hit_latency + cache_miss_count / lookup_count * average_penalty
    return CalibrationResult(
        line_bytes=line_bytes,
        cache_capacity_bytes=cache_capacity_bytes,
        cache_way_count=cache_way_count,
        benchmark_scale=benchmark_scale,
        benchmark_arch=benchmark_arch,
        refill_transport=f"axi-burst+{benchmark_arch}",
        lookup_count=lookup_count,
        cache_hit_count=cache_hit_count,
        cache_miss_count=cache_miss_count,
        average_hit_response_latency_cycles=average_hit_latency,
        average_critical_response_latency_cycles=average_critical_latency,
        average_miss_penalty_cycles=average_penalty,
        average_complete_refill_latency_cycles=average_complete_latency,
        exact_amat_cycles=exact_amat,
        measurement_window_cycles=measurement_cycles,
        measurement_window_retired_instructions=measurement_instructions,
        measurement_window_ipc=measurement_ipc,
    )


def write_results(results: list[CalibrationResult], output_path: pathlib.Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    ordered_results = sorted(results, key=lambda result: result.line_bytes)
    with output_path.open("w", newline="", encoding="utf-8") as output_file:
        writer = csv.DictWriter(
            output_file, fieldnames=list(asdict(ordered_results[0]).keys())
        )
        writer.writeheader()
        for result in ordered_results:
            writer.writerow(asdict(result))


def run_make_perf(
    npc_dir: pathlib.Path,
    line_bytes: int,
    cache_capacity_bytes: int,
    cache_way_count: int,
    benchmark_scale: str,
    benchmark_arch: str,
    log_path: pathlib.Path,
) -> str:
    command = [
        "make",
        "perf",
        "PROJECT=riscv32",
        "NPC_CONFIG=rv32-baseline",
        f"NPC_ICACHE_CAPACITY_BYTES={cache_capacity_bytes}",
        f"NPC_ICACHE_WAY_COUNT={cache_way_count}",
        f"NPC_ICACHE_LINE_BYTES={line_bytes}",
        "NPC_SDRAM_NATIVE_READ_BURST=1",
        f"PERF_ARCH={benchmark_arch}",
        f"PERF_SCALE={benchmark_scale}",
    ]
    print(f"\nRunning {line_bytes}B calibration:")
    print("  " + " ".join(command))

    output_parts = []
    process = subprocess.Popen(
        command,
        cwd=npc_dir,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    for line in process.stdout:
        print(line, end="")
        output_parts.append(line)

    return_code = process.wait()
    output = "".join(output_parts)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(output, encoding="utf-8")
    if return_code != 0:
        raise RuntimeError(
            f"{line_bytes}B calibration failed with exit code {return_code}; "
            f"log saved to {log_path}"
        )
    return output


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Measure per-line-size I-cache miss penalties in RTL"
    )
    parser.add_argument("--npc-dir", type=pathlib.Path, required=True)
    parser.add_argument("--line-sizes", default="16,32,64")
    parser.add_argument("--cache-capacity-bytes", type=int, default=64)
    parser.add_argument("--cache-way-count", type=int, default=1)
    parser.add_argument(
        "--benchmark-arch",
        choices=("riscv32-ysyxsoc-psram", "riscv32-ysyxsoc-sdram"),
        default="riscv32-ysyxsoc-psram",
    )
    parser.add_argument(
        "--scale", choices=("test", "train", "ref", "huge"), default="test"
    )
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    npc_dir = args.npc_dir.resolve()
    output_path = args.output.resolve()
    line_sizes = parse_line_sizes(args.line_sizes)
    log_dir = output_path.parent / "calibration_logs"
    results = []

    for line_bytes in line_sizes:
        log_path = log_dir / f"{output_path.stem}-{line_bytes}B.log"
        output = run_make_perf(
            npc_dir,
            line_bytes,
            args.cache_capacity_bytes,
            args.cache_way_count,
            args.scale,
            args.benchmark_arch,
            log_path,
        )
        result = parse_calibration_output(
            output,
            line_bytes,
            args.cache_capacity_bytes,
            args.cache_way_count,
            args.scale,
            args.benchmark_arch,
        )
        results.append(result)
        write_results(results, output_path)
        print(
            f"Recorded {line_bytes}B: miss penalty="
            f"{result.average_miss_penalty_cycles:.3f}, complete refill="
            f"{result.average_complete_refill_latency_cycles:.3f} cycles"
        )

    critical_map = ",".join(
        f"{result.line_bytes}={result.average_miss_penalty_cycles:.3f}"
        for result in sorted(results, key=lambda item: item.line_bytes)
    )
    complete_map = ",".join(
        f"{result.line_bytes}={result.average_complete_refill_latency_cycles:.3f}"
        for result in sorted(results, key=lambda item: item.line_bytes)
    )
    print("\nCalibration complete:")
    print(f"  result = {output_path}")
    print(f"  CACHE_CRITICAL_RESPONSE_PENALTY_BY_LINE_SIZE={critical_map}")
    print(f"  CACHE_COMPLETE_REFILL_PENALTY_BY_LINE_SIZE={complete_map}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
