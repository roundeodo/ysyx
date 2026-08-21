#!/usr/bin/env python3

import argparse
import csv
import json
import subprocess
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path


def parse_integer_list(text):
    return [int(value, 0) for value in text.split(",") if value]


def parse_penalty_map(text):
    penalty_by_line_size = {}
    for item in text.split(","):
        line_size, penalty = item.split("=", 1)
        penalty_by_line_size[int(line_size, 0)] = float(penalty)
    return penalty_by_line_size


def run_configuration(arguments):
    (
        binary,
        trace_path,
        capacity,
        line_size,
        ways,
        hit_time,
        refill_model,
        refill_beat_bytes,
        miss_penalty,
        read_address_cycles,
        memory_command_cycles,
        first_data_cycles,
        response_beat_cycles,
    ) = arguments
    command = [
        str(binary),
        "--trace",
        str(trace_path),
        "--capacity-bytes",
        str(capacity),
        "--line-bytes",
        str(line_size),
        "--ways",
        str(ways),
        "--hit-time-cycles",
        str(hit_time),
        "--refill-model",
        refill_model,
        "--refill-beat-bytes",
        str(refill_beat_bytes),
        "--miss-penalty-cycles",
        str(miss_penalty),
        "--read-address-cycles",
        str(read_address_cycles),
        "--memory-command-cycles",
        str(memory_command_cycles),
        "--first-data-cycles",
        str(first_data_cycles),
        "--response-beat-cycles",
        str(response_beat_cycles),
        "--output-format",
        "json",
    ]
    completed = subprocess.run(command, check=True, text=True, capture_output=True)
    return json.loads(completed.stdout)


def main():
    parser = argparse.ArgumentParser(
        description="并行扫描 I-cache 容量、行大小和路数"
    )
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--capacities", default="4096,8192,16384,32768")
    parser.add_argument("--line-sizes", default="16,32,64")
    parser.add_argument("--ways", default="1,2,4")
    parser.add_argument("--hit-time-cycles", type=float, default=2.0)
    parser.add_argument(
        "--refill-model",
        choices=("fixed", "independent", "burst"),
        default="fixed",
    )
    parser.add_argument("--refill-beat-bytes", type=int, default=4)
    parser.add_argument("--miss-penalty-cycles", type=float, default=0.0)
    parser.add_argument(
        "--miss-penalty-by-line-size",
        help="按行大小提供缺失代价，例如 16=150,32=284.142,64=520",
    )
    parser.add_argument("--read-address-cycles", type=float, default=1.0)
    parser.add_argument("--memory-command-cycles", type=float, default=1.0)
    parser.add_argument("--first-data-cycles", type=float, default=1.0)
    parser.add_argument("--response-beat-cycles", type=float, default=1.0)
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    capacities = parse_integer_list(args.capacities)
    line_sizes = parse_integer_list(args.line_sizes)
    way_counts = parse_integer_list(args.ways)
    penalty_by_line_size = (
        parse_penalty_map(args.miss_penalty_by_line_size)
        if args.miss_penalty_by_line_size
        else {}
    )

    configurations = []
    for capacity in capacities:
        for line_size in line_sizes:
            for ways in way_counts:
                if capacity < line_size * ways:
                    continue
                if capacity % (line_size * ways) != 0:
                    continue
                miss_penalty = penalty_by_line_size.get(
                    line_size, args.miss_penalty_cycles
                )
                configurations.append(
                    (
                        args.binary,
                        args.trace,
                        capacity,
                        line_size,
                        ways,
                        args.hit_time_cycles,
                        args.refill_model,
                        args.refill_beat_bytes,
                        miss_penalty,
                        args.read_address_cycles,
                        args.memory_command_cycles,
                        args.first_data_cycles,
                        args.response_beat_cycles,
                    )
                )

    with ProcessPoolExecutor(max_workers=args.jobs) as executor:
        results = list(executor.map(run_configuration, configurations))

    results.sort(
        key=lambda result: (
            result["critical_tmt_cycles"],
            result["misses"],
            result["capacity_bytes"],
            result["ways"],
        )
    )

    field_names = [
        "capacity_bytes",
        "line_bytes",
        "ways",
        "sets",
        "accesses",
        "hits",
        "misses",
        "compulsory_misses",
        "capacity_misses",
        "conflict_misses",
        "unique_lines",
        "hit_rate",
        "miss_rate",
        "hit_time_cycles",
        "refill_model",
        "refill_beat_bytes",
        "refill_beats_per_line",
        "average_critical_beat_position",
        "read_address_cycles",
        "memory_command_cycles",
        "first_data_cycles",
        "response_beat_cycles",
        "fixed_miss_penalty_cycles",
        "average_critical_response_penalty_cycles",
        "average_complete_refill_penalty_cycles",
        "amat_cycles",
        "critical_tmt_cycles",
        "refill_occupancy_cycles",
        "read_transactions",
        "transferred_refill_beats",
        "refill_traffic_bytes",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=field_names)
        writer.writeheader()
        for result in results:
            writer.writerow({name: result[name] for name in field_names})

    print(
        "capacity  line  ways      misses   hit rate   critical penalty  complete refill       AMAT   critical TMT"
    )
    for result in results[: min(12, len(results))]:
        print(
            f"{result['capacity_bytes']:>8}  "
            f"{result['line_bytes']:>4}  "
            f"{result['ways']:>4}  "
            f"{result['misses']:>10}  "
            f"{result['hit_rate'] * 100:>8.4f}%  "
            f"{result['average_critical_response_penalty_cycles']:>16.3f}  "
            f"{result['average_complete_refill_penalty_cycles']:>15.3f}  "
            f"{result['amat_cycles']:>9.4f}  "
            f"{result['critical_tmt_cycles']:>13.3f}"
        )
    print(f"\n完整结果: {args.output}")


if __name__ == "__main__":
    main()
