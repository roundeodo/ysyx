#!/usr/bin/env python3
"""Calibrate observed code/control-flow footprints; no claim of a complete data working set."""
import collections
import json
import subprocess
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC/'result/branch-v3'


def main():
    records = []
    for run, dataset in [('B0-opportunity','images'), ('B0-latest-stream-development','streams-development'),
                         ('B0-latest-stream-validation','streams-validation')]:
        manifest = json.loads((ROOT/dataset/'manifest.json').read_text())
        cases = {case['name']: case for case in manifest['cases']}
        for path in sorted((ROOT/'rtl'/run).glob('*.events')):
            case = cases[path.stem]
            instructions, retired, branches = {}, [], []
            inside = False
            for line in path.open():
                row = line.strip().split(',')
                if row[0] == 'C':
                    pc = int(row[3],16)
                    if inside:
                        retired.append(pc)
                        instructions[pc] = int(row[4],16)
                    if pc == case['begin_pc']:
                        inside = True
                    if pc == case['end_pc']:
                        inside = False
                elif row[0] == 'R':
                    branches.append(row)
            types, bias, reuse = collections.Counter(), collections.defaultdict(collections.Counter), collections.Counter()
            last, targets = {}, collections.defaultdict(set)
            for position, row in enumerate(branches):
                pc, target, kind, taken = int(row[3],16), int(row[4],16), int(row[5]), bool(int(row[6]))
                ins = instructions[pc]
                rd, rs1 = (ins>>7)&31, (ins>>15)&31
                returned = kind == 3 and rs1 in (1,5) and (rd not in (1,5) or rd != rs1)
                label = 'conditional' if kind == 1 else 'jal' if kind == 2 else 'return' if returned else 'indirect'
                types[label] += 1
                bias[hex(pc)]['taken' if taken else 'not_taken'] += 1
                targets[hex(pc)].add(target)
                if pc in last:
                    distance = position-last[pc]
                    reuse[str(1 << (distance.bit_length()-1))] += 1
                else:
                    reuse['cold'] += 1
                last[pc] = position
            elf = ROOT/dataset/path.stem/'image.elf'
            size = subprocess.check_output(['riscv64-linux-gnu-size', str(elf)], text=True)
            records.append({'dataset': dataset, 'case': path.stem, 'retired': len(retired),
                            'distinct_retired_pcs': len(set(retired)),
                            'distinct_retired_32B_lines': len({pc>>5 for pc in retired}),
                            'branch_types': dict(types), 'static_pc_taken_counts': dict(bias),
                            'static_pc_target_count': {key:len(value) for key,value in targets.items()},
                            'branch_instance_reuse_lower_power2': dict(reuse),
                            'elf_section_size_output': size})
    (NPC/'docs/research/branch-v3/workload-profiles.json').write_text(json.dumps({
        'limits': 'ROI code footprint and branch-instance reuse; ELF sections are not measured dynamic data working sets',
        'records': records}, indent=2)+'\n')
    print('PASS workload footprint calibration', len(records))


if __name__ == '__main__':
    main()
