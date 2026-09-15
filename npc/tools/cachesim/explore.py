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


def parse_penalty_calibration(path):
    critical_penalty_by_line_size = {}
    complete_penalty_by_line_size = {}
    with path.open(newline="", encoding="utf-8") as calibration_file:
        reader = csv.DictReader(calibration_file)
        required_fields = {
            "line_bytes",
            "average_miss_penalty_cycles",
            "average_complete_refill_latency_cycles",
        }
        if reader.fieldnames is None or not required_fields.issubset(reader.fieldnames):
            raise ValueError(
                "penalty calibration CSV must contain line_bytes, "
                "average_miss_penalty_cycles, and "
                "average_complete_refill_latency_cycles"
            )
        for row in reader:
            line_size = int(row["line_bytes"], 0)
            if line_size in critical_penalty_by_line_size:
                raise ValueError(
                    f"duplicate {line_size}B entry in penalty calibration CSV"
                )
            critical_penalty_by_line_size[line_size] = float(
                row["average_miss_penalty_cycles"]
            )
            complete_penalty_by_line_size[line_size] = float(
                row["average_complete_refill_latency_cycles"]
            )
    return critical_penalty_by_line_size, complete_penalty_by_line_size


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
        critical_response_penalty,
        complete_refill_penalty,
        dirty_writeback_penalty,
        read_address_cycles,
        memory_command_cycles,
        first_data_cycles,
        response_beat_cycles,
        write_address_cycles,
        write_data_beat_cycles,
        write_response_cycles,
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
        "--critical-response-penalty-cycles",
        str(critical_response_penalty),
        "--complete-refill-penalty-cycles",
        str(complete_refill_penalty),
        "--dirty-writeback-penalty-cycles",
        str(dirty_writeback_penalty),
        "--read-address-cycles",
        str(read_address_cycles),
        "--memory-command-cycles",
        str(memory_command_cycles),
        "--first-data-cycles",
        str(first_data_cycles),
        "--response-beat-cycles",
        str(response_beat_cycles),
        "--write-address-cycles",
        str(write_address_cycles),
        "--write-data-beat-cycles",
        str(write_data_beat_cycles),
        "--write-response-cycles",
        str(write_response_cycles),
        "--output-format",
        "json",
    ]
    completed = subprocess.run(command, check=True, text=True, capture_output=True)
    return json.loads(completed.stdout)


def main():
    parser = argparse.ArgumentParser(
        description="并行扫描 I-cache 或 D-cache 的容量、行大小和路数"
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
    parser.add_argument(
        "--critical-response-penalty-cycles", type=float, default=0.0
    )
    parser.add_argument(
        "--complete-refill-penalty-cycles", type=float, default=0.0
    )
    parser.add_argument(
        "--dirty-writeback-penalty-cycles", type=float, default=0.0
    )
    parser.add_argument(
        "--critical-response-penalty-by-line-size",
        help="按行大小提供关键字响应代价，例如 16=4.2,32=4.6,64=6.0",
    )
    parser.add_argument(
        "--complete-refill-penalty-by-line-size",
        help="按行大小提供整行填充代价，例如 16=6,32=10,64=18",
    )
    parser.add_argument(
        "--penalty-calibration-csv",
        type=Path,
        help="读取RTL校准脚本生成的按行大小缺失代价表",
    )
    parser.add_argument("--read-address-cycles", type=float, default=1.0)
    parser.add_argument("--memory-command-cycles", type=float, default=1.0)
    parser.add_argument("--first-data-cycles", type=float, default=1.0)
    parser.add_argument("--response-beat-cycles", type=float, default=1.0)
    parser.add_argument("--write-address-cycles", type=float, default=1.0)
    parser.add_argument("--write-data-beat-cycles", type=float, default=1.0)
    parser.add_argument("--write-response-cycles", type=float, default=1.0)
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument(
        "--ranking-metric",
        choices=("critical-tmt", "blocking-tmt"),
        default="blocking-tmt",
        help="blocking cache使用blocking-tmt；支持early restart或hit-under-miss时可比较critical-tmt",
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    capacities = parse_integer_list(args.capacities)
    line_sizes = parse_integer_list(args.line_sizes)
    way_counts = parse_integer_list(args.ways)
    critical_penalty_by_line_size = {}
    complete_penalty_by_line_size = {}
    if args.penalty_calibration_csv:
        if args.refill_model != "fixed":
            parser.error("--penalty-calibration-csv requires --refill-model fixed")
        (
            critical_penalty_by_line_size,
            complete_penalty_by_line_size,
        ) = parse_penalty_calibration(args.penalty_calibration_csv)

    explicit_critical_penalty_by_line_size = (
        parse_penalty_map(args.critical_response_penalty_by_line_size)
        if args.critical_response_penalty_by_line_size
        else {}
    )
    explicit_complete_penalty_by_line_size = (
        parse_penalty_map(args.complete_refill_penalty_by_line_size)
        if args.complete_refill_penalty_by_line_size
        else {}
    )
    critical_penalty_by_line_size.update(
        explicit_critical_penalty_by_line_size
    )
    complete_penalty_by_line_size.update(
        explicit_complete_penalty_by_line_size
    )

    if args.penalty_calibration_csv:
        missing_line_sizes = sorted(
            line_size
            for line_size in line_sizes
            if line_size not in critical_penalty_by_line_size
            or line_size not in complete_penalty_by_line_size
        )
        if missing_line_sizes:
            raise ValueError(
                "penalty calibration CSV is missing line sizes: "
                + ",".join(str(line_size) for line_size in missing_line_sizes)
            )

    configurations = []
    for capacity in capacities:
        for line_size in line_sizes:
            for ways in way_counts:
                if capacity < line_size * ways:
                    continue
                if capacity % (line_size * ways) != 0:
                    continue
                critical_response_penalty = critical_penalty_by_line_size.get(
                    line_size, args.critical_response_penalty_cycles
                )
                complete_refill_penalty = complete_penalty_by_line_size.get(
                    line_size, args.complete_refill_penalty_cycles
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
                        critical_response_penalty,
                        complete_refill_penalty,
                        args.dirty_writeback_penalty_cycles,
                        args.read_address_cycles,
                        args.memory_command_cycles,
                        args.first_data_cycles,
                        args.response_beat_cycles,
                        args.write_address_cycles,
                        args.write_data_beat_cycles,
                        args.write_response_cycles,
                    )
                )

    with ProcessPoolExecutor(max_workers=args.jobs) as executor:
        results = list(executor.map(run_configuration, configurations))

    ranking_field = (
        "blocking_tmt_cycles"
        if args.ranking_metric == "blocking-tmt"
        else "critical_tmt_cycles"
    )
    results.sort(
        key=lambda result: (
            result[ranking_field],
            result["misses"],
            result["capacity_bytes"],
            result["ways"],
        )
    )

    field_names = [
        "trace_kind",
        "capacity_bytes",
        "line_bytes",
        "ways",
        "sets",
        "architectural_accesses",
        "loads",
        "stores",
        "accesses",
        "hits",
        "misses",
        "compulsory_misses",
        "capacity_misses",
        "conflict_misses",
        "unique_lines",
        "dirty_evictions",
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
        "write_address_cycles",
        "write_data_beat_cycles",
        "write_response_cycles",
        "fixed_critical_response_penalty_cycles",
        "fixed_complete_refill_penalty_cycles",
        "dirty_writeback_penalty_cycles",
        "average_critical_response_penalty_cycles",
        "average_complete_refill_penalty_cycles",
        "average_dirty_writeback_penalty_cycles",
        "amat_cycles",
        "blocking_amat_cycles",
        "critical_tmt_cycles",
        "blocking_tmt_cycles",
        "refill_occupancy_cycles",
        "dirty_writeback_cycles",
        "read_transactions",
        "transferred_refill_beats",
        "refill_traffic_bytes",
        "writeback_traffic_bytes",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=field_names)
        writer.writeheader()
        for result in results:
            writer.writerow({name: result[name] for name in field_names})

    print(
        "capacity  line  ways      misses   hit rate   critical penalty  complete refill       AMAT  blocking AMAT     ranking TMT"
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
            f"{result['blocking_amat_cycles']:>13.4f}  "
            f"{result[ranking_field]:>14.3f}"
        )
    print(f"\n完整结果: {args.output}")


if __name__ == "__main__":
    main()
