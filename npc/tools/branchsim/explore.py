#!/usr/bin/env python3

import argparse
import concurrent.futures
import csv
import itertools
import pathlib
import subprocess


RESULT_KEYS = (
    "predictor",
    "direction_entries",
    "history_bits",
    "btb_entries",
    "btb_ways",
    "ras_entries",
    "instructions",
    "control_flow",
    "conditional",
    "conditional_taken",
    "jal",
    "jalr",
    "calls",
    "returns",
    "direction_errors",
    "direct_jump_errors",
    "indirect_target_errors",
    "btb_hits",
    "btb_misses",
    "conditional_btb_misses",
    "direct_jump_btb_misses",
    "indirect_jump_btb_misses",
    "ras_predictions",
    "mispredictions",
    "accuracy",
    "mpki",
    "storage_bits",
    "ipc_5stage_1wide",
    "ipc_15stage_1wide",
    "ipc_15stage_4wide",
)


def parse_integer_list(text: str):
    return [int(value, 0) for value in text.split(",") if value]


def run_configuration(binary, trace, configuration):
    predictor, direction_entries, history_bits, btb_entries, btb_ways, ras_entries = configuration
    command = [
        str(binary),
        "--trace",
        str(trace),
        "--predictor",
        predictor,
        "--direction-entries",
        str(direction_entries),
        "--history-bits",
        str(history_bits),
        "--btb-entries",
        str(btb_entries),
        "--btb-ways",
        str(btb_ways),
        "--ras-entries",
        str(ras_entries),
    ]
    completed = subprocess.run(command, check=True, text=True, capture_output=True)
    result = {}
    for line in completed.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in RESULT_KEYS:
            result[key] = value
    missing_keys = set(RESULT_KEYS) - result.keys()
    if missing_keys:
        raise RuntimeError(f"branchsim output missing keys: {sorted(missing_keys)}")
    return result


def build_configuration_array(args):
    configuration_array = [
        ("sequential", 1, 1, 0, 1, 0),
        ("btfnt", 1, 1, 0, 1, 0),
    ]

    target_configuration_array = list(
        itertools.product(args.btb_entries, args.btb_ways, args.ras_entries)
    )
    for direction_entries in args.direction_entries:
        for btb_entries, btb_ways, ras_entries in target_configuration_array:
            if btb_entries == 0 or btb_ways > btb_entries:
                continue
            configuration_array.append(
                ("bimodal", direction_entries, 1, btb_entries, btb_ways, ras_entries)
            )
            maximum_history_bits = direction_entries.bit_length() - 1
            for history_bits in args.history_bits:
                if 0 < history_bits <= maximum_history_bits:
                    configuration_array.append(
                        (
                            "gshare",
                            direction_entries,
                            history_bits,
                            btb_entries,
                            btb_ways,
                            ras_entries,
                        )
                    )
    return configuration_array


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Explore branch direction and indirect-target predictors"
    )
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--trace", required=True, type=pathlib.Path)
    parser.add_argument("--direction-entries", default="16,32,64,128,256")
    parser.add_argument("--history-bits", default="2,4,6,8")
    parser.add_argument("--btb-entries", default="0,32,64")
    parser.add_argument("--btb-ways", default="1,2")
    parser.add_argument("--ras-entries", default="0,8")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    args.direction_entries = parse_integer_list(args.direction_entries)
    args.history_bits = parse_integer_list(args.history_bits)
    args.btb_entries = parse_integer_list(args.btb_entries)
    args.btb_ways = parse_integer_list(args.btb_ways)
    args.ras_entries = parse_integer_list(args.ras_entries)

    configuration_array = build_configuration_array(args)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        result_array = list(
            executor.map(
                lambda configuration: run_configuration(
                    args.binary, args.trace, configuration
                ),
                configuration_array,
            )
        )

    result_array.sort(
        key=lambda result: (
            int(result["mispredictions"]),
            int(result["storage_bits"]),
        )
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=RESULT_KEYS)
        writer.writeheader()
        writer.writerows(result_array)

    print(f"evaluated {len(result_array)} predictor configurations")
    print(f"results: {args.output}")
    print("best configurations:")
    for result in result_array[:10]:
        print(
            "  "
            f"{result['predictor']:10s} BHT={result['direction_entries']:>4s} "
            f"hist={result['history_bits']:>2s} "
            f"BTB={result['btb_entries']:>3s}x{result['btb_ways']} "
            f"RAS={result['ras_entries']:>2s} "
            f"misp={result['mispredictions']:>8s} "
            f"MPKI={float(result['mpki']):8.3f} "
            f"storage={result['storage_bits']:>7s} bits"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
