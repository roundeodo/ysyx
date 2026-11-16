#!/usr/bin/env python3
"""Screen target encodings on cold retired control flow, without timing claims."""
import argparse
from collections import Counter, OrderedDict
import json
import math
from pathlib import Path
from model_branch import decode
from explore_frontend import sha


class TargetTable:
    def __init__(self, entries, widths):
        self.widths = widths
        self.sets = entries // len(widths)
        self.table = [[None] * len(widths) for _ in range(self.sets)]
        self.cursor = [0] * self.sets

    def lookup(self, pc):
        row = self.table[(pc >> 2) & (self.sets - 1)]
        return next((entry for entry in row if entry is not None and entry[0] == pc), None)

    def update(self, pc, target, kind):
        index = (pc >> 2) & (self.sets - 1)
        row = self.table[index]
        allowed = [(pc >> width) == (target >> width) for width in self.widths]
        hit = next((way for way, entry in enumerate(row) if entry is not None and entry[0] == pc), None)
        if hit is not None and not allowed[hit]:
            row[hit] = None
            hit = None
        if hit is not None:
            chosen = hit
        else:
            chosen = next((way for way, entry in enumerate(row) if allowed[way] and entry is None), None)
            if chosen is None:
                chosen = next(((self.cursor[index] + step) % len(row) for step in range(len(row))
                               if allowed[(self.cursor[index] + step) % len(row)]), None)
                if chosen is not None:
                    self.cursor[index] = (chosen + 1) % len(row)
        if chosen is not None:
            row[chosen] = (pc, target, kind)
        return chosen is not None

    def bits(self):
        tag = 30 - (self.sets.bit_length() - 1)
        return self.sets * (sum(tag + width + 3 for width in self.widths) + (len(self.widths).bit_length() - 1))


def evaluate(records, entries, widths):
    table = TargetTable(entries, widths)
    counters = [1] * 16
    stack = []
    seen = set()
    fully_associative = OrderedDict()
    counts = Counter()
    required_bits = Counter()
    for pc, kind, taken, target, push, pop in records:
        entry = table.lookup(pc)
        index = (pc >> 2) & 15
        predicted_taken = entry is not None and (entry[2] != 0 or counters[index] >= 2)
        predicted_target = stack[-1] if entry is not None and entry[2] == 3 and stack else entry[1] if entry else 0
        predicted_next = predicted_target if predicted_taken else pc + 4
        actual_next = target if taken else pc + 4
        required_bits[(pc ^ target).bit_length()] += 1
        counts['branches'] += 1
        if predicted_next != actual_next:
            counts['errors'] += 1
            if entry is None:
                category = 'untrained' if pc not in seen else 'mapping_or_replacement' if pc in fully_associative else 'capacity'
                counts['missing_' + category] += 1
            elif predicted_taken != taken:
                counts['direction'] += 1
            else:
                counts['target'] += 1
        if kind == 0:
            counters[index] = min(3, counters[index] + 1) if taken else max(0, counters[index] - 1)
        if not table.update(pc, target, kind):
            counts['not_representable'] += 1
        seen.add(pc)
        fully_associative.pop(pc, None)
        fully_associative[pc] = True
        if len(fully_associative) > entries:
            fully_associative.popitem(last=False)
        if pop and stack:
            stack.pop()
        if push:
            stack.append((pc + 4) & 0xffffffff)
            stack = stack[-4:]
    return {'counts': dict(counts), 'target_required_bits': dict(sorted(required_bits.items())),
            'btb_state_bits': table.bits(), 'static_branch_pcs': len(seen)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--trace-root', type=Path, required=True)
    parser.add_argument('--label', default='model')
    args = parser.parse_args()
    root = args.root.resolve()
    output = root / args.label
    output.mkdir(exist_ok=False)
    configs = {}
    for entries in [16, 32]:
        configs[f'F{entries}'] = {'entries': entries, 'widths': [32, 32]}
        configs[f'F{entries}W4'] = {'entries': entries, 'widths': [32, 32, 32, 32]}
        for width in [8, 10, 12, 16]:
            configs[f'U{entries}w{width}'] = {'entries': entries, 'widths': [width, width]}
        for width in [8, 10, 12]:
            configs[f'X{entries}w{width}'] = {'entries': entries, 'widths': [width, 32]}
        for widths in [[8, 8, 8, 32], [8, 8, 16, 32], [8, 12, 16, 32], [8, 12, 16, 16]]:
            name = f'H{entries}w' + '-'.join(map(str, widths))
            configs[name] = {'entries': entries, 'widths': widths}
    cases = json.loads((root / 'images/manifest.json').read_text())['cases']
    results = {}
    for case in cases:
        if case['held']:
            continue
        path = args.trace_root / (case['name'] + '.trace')
        records = []
        total = 0
        for line in path.read_text().splitlines():
            pc, instruction, following, cycle = line.split(',')
            record = decode(int(pc, 16), int(instruction, 16), int(following, 16))
            total += 1
            if record:
                records.append(record)
        results[case['name']] = {'family': case['kind'], 'trace_sha256': sha(path),
                                'instructions': total, 'configurations': {
                                    name: evaluate(records, **config) for name, config in configs.items()}}
        print('MODEL', case['name'], len(records), flush=True)
    summary = {}
    for name in configs:
        family = {}
        for row in results.values():
            candidates = row['configurations']
            family.setdefault(row['family'], []).append(candidates[name]['counts'].get('errors', 0) / candidates['F16']['counts']['errors'])
        family = {kind: math.exp(sum(map(math.log, values)) / len(values)) for kind, values in family.items()}
        summary[name] = {'error_ratio_gm': math.exp(sum(map(math.log, family.values())) / len(family)),
                         'families': family, 'btb_state_bits': next(iter(results.values()))['configurations'][name]['btb_state_bits']}
    report = {'scope': 'retired control flow, cold state, immediate training, no wrong path or latency; 3C is relative to training-updated full-associative LRU shadow',
              'configs': configs, 'cases': results, 'summary': summary}
    report['model_source_sha256'] = sha(Path(__file__))
    (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    for name, row in sorted(summary.items(), key=lambda item: item[1]['error_ratio_gm']):
        print(name, round(row['error_ratio_gm'], 4), row['btb_state_bits'], flush=True)


if __name__ == '__main__':
    main()
