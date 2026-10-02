#!/usr/bin/env python3
"""Author reference on real call prefixes; immediate-training M0, not CPU time."""
import hashlib
import json
import subprocess
from pathlib import Path
from trace_io import event_files, open_text, sha_uncompressed

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC / 'result/branch-v3'


def sha(path):
    return sha_uncompressed(path)


def main():
    output = ROOT / 'author-warmup'
    output.mkdir(exist_ok=False)
    records = []
    executable = ROOT / 'references/author8'
    for split in ('development', 'validation'):
        manifest = json.loads((ROOT / f'streams-{split}/manifest.json').read_text())
        for case in manifest['cases']:
            path = ROOT / f'rtl/B0-latest-stream-{split}' / (case['name'] + '.events')
            commits, resolved, scored = {}, [], set()
            inside = False
            for line in open_text(path):
                row = line.strip().split(',')
                if row[0] == 'C':
                    identity, pc = int(row[1]), int(row[3], 16)
                    commits[identity] = int(row[4], 16)
                    if inside:
                        scored.add(identity)
                    if pc == case['begin_pc']:
                        inside = True
                    if pc == case['end_pc']:
                        inside = False
                elif row[0] == 'F':
                    resolved.append(row)
            last_scored = max(scored)
            for mode in ('roi-cold', 'natural-prefix'):
                payload = []
                types = {}
                for row in resolved:
                    identity = int(row[1])
                    if identity not in commits:
                        continue  # Architectural stream only, never train squashed work.
                    score = identity in scored
                    if mode == 'roi-cold' and not score:
                        continue
                    # Drop the validation epilogue; prefix is allowed, suffix is not.
                    if identity > last_scored:
                        continue
                    instruction = commits[identity]
                    rd, rs1 = (instruction >> 7) & 31, (instruction >> 15) & 31
                    kind = int(row[5])
                    if kind == 1:
                        operation = 0
                    elif kind == 2:
                        operation = 3 if rd in (1, 5) else 1
                    elif rs1 in (1, 5) and (rd not in (1, 5) or rd != rs1):
                        operation = 4
                    else:
                        operation = 5 if rd in (1, 5) else 2
                    payload.append(f'{row[3]} {row[4]} {operation} {row[6]} {int(score)}\n')
                    if score:
                        types[operation] = types.get(operation, 0) + 1
                stem = f"{split}-{case['name']}-{mode}"
                data = ''.join(payload)
                (output / (stem + '.input')).write_text(data)
                result = subprocess.run([str(executable)], input=data, text=True,
                                        capture_output=True, check=True)
                (output / (stem + '.log')).write_text(result.stdout + result.stderr)
                answer = json.loads(next(line.strip() for line in result.stdout.splitlines()
                                         if line.strip().startswith('{')))
                records.append({'split': split, 'case': case['name'], 'mode': mode,
                                'branch_types': types, 'source_sha256': sha(path),
                                'input_sha256': sha(output / (stem + '.input')), **answer})
    document = {'scope': 'M0 author CBP2016 8KB, immediate sequential training; '
                         'natural prefix is not claimed to reach convergence',
                'executable_sha256': sha(executable),
                'adapter_sha256': sha(NPC / 'tools/branch_v3/author_reference.cpp'),
                'records': records}
    (NPC / 'docs/research/branch-v3/author-warmup.json').write_text(
        json.dumps(document, indent=2) + '\n')
    print('PASS author cold/natural prefix', len(records))


if __name__ == '__main__':
    main()
