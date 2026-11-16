#!/usr/bin/env python3
"""Compare identical RV64 binaries on two simulators; both runs must pass DiffTest."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--current', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    benchmarks = ("div_overlap", "mul_stream", "independent_alu", "same_rd_chain", "raw_chain",
                  "div_load_overlap", "same_rd_producers", "load_store_stream")
    parser.add_argument("--case", choices=benchmarks, help="Run only this workload")
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists():
        raise SystemExit(f"Preserve previous results: {out}")
    out.mkdir(parents=True)
    source = Path(__file__).with_name('scoreboard_overlap.S').resolve()
    record = {'runner_sha256': digest(Path(__file__)), 'source': str(source), 'source_sha256': digest(source), 'simulators': {}, 'cases': []}
    for name in ('baseline', 'current', 'reference'):
        path = getattr(args, name).resolve()
        record['simulators'][name] = {'path': str(path), 'sha256': digest(path)}
    for kind, name in enumerate(benchmarks):
        if args.case and name != args.case:
            continue
        elf, binary = out / (name + '.elf'), out / (name + '.bin')
        command = ['riscv64-linux-gnu-gcc', '-march=rv64im_zicsr_zifencei', '-mabi=lp64',
                   '-nostdlib', '-static', '-Wl,--no-relax,--build-id=none,-Ttext=0x80000000,-e,_start',
                   f'-DBENCH_KIND={kind}', '-o', str(elf), str(source)]
        subprocess.run(command, check=True)
        subprocess.run(['riscv64-linux-gnu-objcopy', '-O', 'binary', str(elf), str(binary)], check=True)
        case = {'name': name, 'build_command': command, 'binary_sha256': digest(binary)}
        for simulator in ('baseline', 'current'):
            run = [str(getattr(args, simulator).resolve()), '--batch', '--diff',
                   str(args.reference.resolve()), str(binary)]
            log_path = out / f'{name}-{simulator}.log'
            with log_path.open('w') as log:
                result = subprocess.run(run, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            text = log_path.read_text(errors='replace')
            cycles = re.search(r'active core cycles\s*:\s*(\d+)', text)
            retired = re.search(r'retired instructions\s*:\s*(\d+)', text)
            passed = result.returncode == 0 and 'HIT GOOD TRAP' in text and cycles and retired
            if not passed:
                raise RuntimeError(f'{name}/{simulator} failed: {log_path}')
            case[simulator] = {'command': run, 'exit': result.returncode,
                               'cycles': int(cycles[1]), 'retired': int(retired[1]),
                               'ipc': int(retired[1]) / int(cycles[1])}
        if case['baseline']['retired'] != case['current']['retired']:
            raise RuntimeError(f'Retired instruction counts differ in {name}')
        case['cycle_reduction_percent'] = 100 * (1 - case['current']['cycles'] / case['baseline']['cycles'])
        case['ipc_change_percent'] = 100 * (case['current']['ipc'] / case['baseline']['ipc'] - 1)
        record['cases'].append(case)
        (out / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n')
        print(f"{name}: cycles {case['baseline']['cycles']} -> {case['current']['cycles']}; "
              f"IPC change {case['ipc_change_percent']:+.2f}%", flush=True)


if __name__ == '__main__':
    main()
