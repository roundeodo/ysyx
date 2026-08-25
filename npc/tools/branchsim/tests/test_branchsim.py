#!/usr/bin/env python3

import pathlib
import struct
import subprocess
import sys
import tempfile


HEADER_FORMAT = "<8sIIQQ"
RECORD_FORMAT = "<QQQII"


def write_test_trace(trace_path: pathlib.Path) -> None:
    # Four dynamic instances of one backward conditional branch: T, T, N, T.
    # A JAL call then places pc+4 in the RAS; the following JALR returns there.
    conditional_instruction = 0xFE0008E3  # beq x0, x0, -16
    jal_call_instruction = 0x000000EF
    jalr_return_instruction = 0x00008067
    record_array = [
        (10, 0x100, 0x0F0, conditional_instruction, 0),
        (20, 0x100, 0x0F0, conditional_instruction, 0),
        (30, 0x100, 0x104, conditional_instruction, 0),
        (40, 0x100, 0x0F0, conditional_instruction, 0),
        (50, 0x200, 0x200, jal_call_instruction, 0),
        (60, 0x304, 0x204, jalr_return_instruction, 0),
    ]
    with trace_path.open("wb") as trace_file:
        trace_file.write(
            struct.pack(
                HEADER_FORMAT,
                b"NPCBRTR1",
                1,
                4,
                100,
                len(record_array),
            )
        )
        for record in record_array:
            trace_file.write(struct.pack(RECORD_FORMAT, *record))


def run_branchsim(binary: pathlib.Path, trace: pathlib.Path, *arguments: str):
    completed = subprocess.run(
        [str(binary), "--trace", str(trace), *arguments],
        check=True,
        text=True,
        capture_output=True,
    )
    result = {}
    for line in completed.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key] = value
    return result


def require_equal(result, key: str, expected: str) -> None:
    actual = result.get(key)
    if actual != expected:
        raise AssertionError(f"{key}: expected {expected}, got {actual}")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} BRANCHSIM_BINARY", file=sys.stderr)
        return 2

    binary = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="branchsim-test-") as directory:
        trace = pathlib.Path(directory) / "control_flow.bin"
        write_test_trace(trace)

        sequential = run_branchsim(binary, trace, "--predictor", "sequential")
        require_equal(sequential, "instructions", "100")
        require_equal(sequential, "control_flow", "6")
        require_equal(sequential, "mispredictions", "5")

        # 请求侧预测器在BTB miss时不知道当前PC是控制流，只能采用PC+4。
        btfnt = run_branchsim(binary, trace, "--predictor", "btfnt")
        require_equal(btfnt, "direction_errors", "3")
        require_equal(btfnt, "mispredictions", "5")

        bimodal = run_branchsim(
            binary,
            trace,
            "--predictor",
            "bimodal",
            "--direction-entries",
            "16",
        )
        require_equal(bimodal, "direction_errors", "3")
        require_equal(bimodal, "mispredictions", "5")

        bimodal_with_btb_and_ras = run_branchsim(
            binary,
            trace,
            "--predictor",
            "bimodal",
            "--direction-entries",
            "16",
            "--btb-entries",
            "16",
            "--ras-entries",
            "4",
        )
        require_equal(bimodal_with_btb_and_ras, "direction_errors", "2")
        require_equal(bimodal_with_btb_and_ras, "direct_jump_errors", "1")
        require_equal(bimodal_with_btb_and_ras, "indirect_target_errors", "1")
        require_equal(bimodal_with_btb_and_ras, "mispredictions", "4")

    print("branchsim directed tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
