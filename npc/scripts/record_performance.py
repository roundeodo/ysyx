#!/usr/bin/env python3

import argparse
import datetime
import pathlib
import re
import subprocess
import sys


RESULT_INSERT_MARKER = "<!-- PERFORMANCE_RESULTS:INSERT_BEFORE -->"


def run_git(repo: pathlib.Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def require_clean_repository(repo: pathlib.Path, label: str) -> None:
    status = run_git(repo, "status", "--porcelain", "--untracked-files=normal")
    if status:
        print(f"error: {label} repository is not clean: {repo}", file=sys.stderr)
        print(status, file=sys.stderr)
        print(
            "Commit the experiment sources before recording a reproducible result.",
            file=sys.stderr,
        )
        raise SystemExit(2)


def parse_frequency_from_sta_report(report_path: pathlib.Path) -> float:
    frequencies = []
    for line in report_path.read_text(encoding="utf-8", errors="replace").splitlines():
        fields = [field.strip() for field in line.strip().strip("|").split("|")]
        if len(fields) != 8 or fields[2] != "max":
            continue
        try:
            frequencies.append(float(fields[7]))
        except ValueError:
            continue

    if not frequencies:
        raise ValueError(f"no numeric max-path Freq(MHz) found in {report_path}")
    return min(frequencies)


def run_performance_test(npc_dir: pathlib.Path, scale: str, log_path: pathlib.Path) -> str:
    # 当前可复现性能基线运行在AXI32 ysyxSoC上。RV64接入SoC边界前，记录脚本必须
    # 显式选择RV32配置，避免调用方的环境变量悄悄改变实验对象。
    command = ["make", "perf", "NPC_CONFIG=rv32-baseline", f"PERF_SCALE={scale}"]
    print(f"Running: {' '.join(command)}")

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
            f"make perf failed with exit code {return_code}; log saved to {log_path}"
        )
    return output


def parse_measurement_window(output: str) -> tuple[int, int, float]:
    pattern = re.compile(
        r"MicroBench PMU measurement window:\s*\n"
        r"\s*cycles\s*=\s*(\d+)\s*\n"
        r"\s*retired instructions\s*=\s*(\d+)\s*\n"
        r"\s*IPC\s*=\s*([0-9]+(?:\.[0-9]+)?)"
    )
    matches = list(pattern.finditer(output))
    if len(matches) != 1:
        raise ValueError(
            "expected exactly one MicroBench PMU measurement window, "
            f"found {len(matches)}"
        )

    cycle_count = int(matches[0].group(1))
    instruction_count = int(matches[0].group(2))
    reported_ipc = float(matches[0].group(3))
    if cycle_count == 0:
        raise ValueError("PMU measurement window reported zero cycles")

    calculated_ipc = instruction_count / cycle_count
    if abs(reported_ipc - calculated_ipc) > 0.000001:
        raise ValueError(
            "reported IPC does not match retired instructions / cycles: "
            f"reported={reported_ipc:.6f}, calculated={calculated_ipc:.6f}"
        )
    return cycle_count, instruction_count, calculated_ipc


def escape_markdown_cell(text: str) -> str:
    return " ".join(text.split()).replace("|", "\\|")


def append_result(
    table_path: pathlib.Path,
    workspace_commit: str,
    am_commit: str,
    scale: str,
    description: str,
    cycle_count: int,
    instruction_count: int,
    ipc: float,
    frequency_mhz: float,
) -> None:
    table = table_path.read_text(encoding="utf-8")
    if RESULT_INSERT_MARKER not in table:
        raise ValueError(f"result insertion marker is missing from {table_path}")

    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    row = (
        f"| {date} | `{workspace_commit[:16]}` | `{am_commit[:16]}` | "
        f"{escape_markdown_cell(scale)} | {escape_markdown_cell(description)} | "
        f"{cycle_count} | {instruction_count} | {ipc:.6f} | {frequency_mhz:.3f} |\n"
    )
    table = table.replace(RESULT_INSERT_MARKER, row + RESULT_INSERT_MARKER, 1)
    table_path.write_text(table, encoding="utf-8")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run NPC MicroBench and append a reproducible performance record."
    )
    parser.add_argument("--npc-dir", type=pathlib.Path, required=True)
    parser.add_argument("--workspace-root", type=pathlib.Path, required=True)
    parser.add_argument("--am-dir", type=pathlib.Path, required=True)
    parser.add_argument("--scale", required=True)
    parser.add_argument("--description", required=True)
    parser.add_argument("--table", type=pathlib.Path, required=True)
    frequency_source = parser.add_mutually_exclusive_group(required=True)
    frequency_source.add_argument("--frequency-mhz", type=float)
    frequency_source.add_argument("--sta-report", type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    npc_dir = args.npc_dir.resolve()
    workspace_root = args.workspace_root.resolve()
    am_dir = args.am_dir.resolve()
    table_path = args.table.resolve()

    require_clean_repository(workspace_root, "ysyx-workbench")
    require_clean_repository(am_dir, "am-kernels")

    workspace_commit = run_git(workspace_root, "rev-parse", "HEAD")
    am_commit = run_git(am_dir, "rev-parse", "HEAD")

    if args.sta_report is not None:
        frequency_mhz = parse_frequency_from_sta_report(args.sta_report.resolve())
    else:
        frequency_mhz = args.frequency_mhz
    if frequency_mhz is None or frequency_mhz <= 0.0:
        raise ValueError("synthesis frequency must be greater than zero")

    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log_path = (
        table_path.parent
        / "logs"
        / f"{timestamp}-{workspace_commit[:12]}-{args.scale}.log"
    )
    output = run_performance_test(npc_dir, args.scale, log_path)
    cycle_count, instruction_count, ipc = parse_measurement_window(output)

    append_result(
        table_path,
        workspace_commit,
        am_commit,
        args.scale,
        args.description,
        cycle_count,
        instruction_count,
        ipc,
        frequency_mhz,
    )

    print("")
    print("Performance result recorded:")
    print(f"  workspace commit = {workspace_commit}")
    print(f"  AM-kernels commit = {am_commit}")
    print(f"  cycles = {cycle_count}")
    print(f"  retired instructions = {instruction_count}")
    print(f"  IPC = {ipc:.6f}")
    print(f"  synthesis frequency = {frequency_mhz:.3f} MHz")
    print(f"  table = {table_path}")
    print(f"  raw log = {log_path}")
    print("Commit the updated table as a separate experiment-record commit.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
