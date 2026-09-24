#!/usr/bin/env python3
"""Development-only direction study; resolved-order model, never CPU timing."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path

from model_branch import decode, evaluate


def saturate(counter, taken):
    return min(3, counter + 1) if taken else max(0, counter - 1)


class CounterTable:
    def __init__(self, entries, history_bits=0, threshold=2, history_shift=0):
        self.table = [1] * entries
        self.history_bits, self.history, self.threshold = history_bits, 0, threshold
        self.history_shift = history_shift

    def index(self, pc):
        return ((pc >> 2) ^ (self.history << self.history_shift)) & (len(self.table) - 1)

    def predict(self, pc, target):
        return self.table[self.index(pc)] >= self.threshold

    def update(self, pc, target, taken):
        index = self.index(pc)
        self.table[index] = saturate(self.table[index], taken)
        self.history = ((self.history << 1) | taken) & ((1 << self.history_bits) - 1)

    def state_bits(self):
        return 2 * len(self.table) + self.history_bits


class BiMode:
    """Lee/Chen/Mudge partial chooser update, scaled to a small total budget."""
    def __init__(self, entries, history_bits):
        self.choice = [1] * (entries // 2)
        self.tables = [[1] * (entries // 4), [2] * (entries // 4)]
        self.history_bits, self.history = history_bits, 0

    def indices(self, pc):
        choice_index = (pc >> 2) & (len(self.choice) - 1)
        index = ((pc >> 2) ^ self.history) & (len(self.tables[0]) - 1)
        bank = int(self.choice[choice_index] >= 2)
        return choice_index, index, bank

    def predict(self, pc, target):
        _, index, bank = self.indices(pc)
        return self.tables[bank][index] >= 2

    def update(self, pc, target, taken):
        choice_index, index, bank = self.indices(pc)
        correct = (self.tables[bank][index] >= 2) == taken
        self.tables[bank][index] = saturate(self.tables[bank][index], taken)
        # Do not overturn a bank choice that correctly recognizes an exception
        # to the branch's bias; this is not a tournament accuracy selector.
        if not correct or bool(bank) == taken:
            self.choice[choice_index] = saturate(self.choice[choice_index], taken)
        self.history = ((self.history << 1) | taken) & ((1 << self.history_bits) - 1)

    def state_bits(self):
        return 2 * (len(self.choice) + 2 * len(self.tables[0])) + self.history_bits


class LoopTable:
    """Experimental backward-loop override; no ISA changes or speculative state.

    Full PC tags, round-robin allocation, 8-bit trip/current count and two-bit
    confidence. Only stable T...TN sequences override a 64-entry bimodal table.
    Overflow and changing trip counts stop overrides until stable retraining.
    This is a local study variant, not a reproduction of TAGE-SC-L's loop unit.
    """
    def __init__(self, entries):
        self.base = CounterTable(64)
        self.entries = [None] * entries
        self.victim = 0
        self.overrides = 0

    def find(self, pc):
        return next((entry for entry in self.entries if entry and entry['pc'] == pc), None)

    def predict(self, pc, target):
        entry = self.find(pc) if target < pc else None
        if entry and entry['confidence'] == 3 and not entry['overflow']:
            self.overrides += 1
            return entry['current'] < entry['trip']
        return self.base.predict(pc, target)

    def update(self, pc, target, taken):
        self.base.update(pc, target, taken)
        if target >= pc:
            return
        entry = self.find(pc)
        if entry is None:
            slot = next((i for i, value in enumerate(self.entries) if value is None), self.victim)
            if self.entries[slot] is not None:
                self.victim = (slot + 1) % len(self.entries)
            entry = dict(pc=pc, current=0, trip=0, confidence=0, overflow=False)
            self.entries[slot] = entry
        if taken:
            if entry['current'] == 255:
                entry['overflow'] = True
                entry['confidence'] = 0
            else:
                entry['current'] += 1
                if entry['current'] > entry['trip']:
                    entry['confidence'] = 0
        else:
            if not entry['overflow'] and entry['current'] > 0:
                if entry['current'] == entry['trip']:
                    entry['confidence'] = min(3, entry['confidence'] + 1)
                else:
                    entry['trip'] = entry['current']
                    entry['confidence'] = 0
            else:
                entry['confidence'] = 0
            entry['current'], entry['overflow'] = 0, False

    def state_bits(self):
        return self.base.state_bits() + len(self.entries) * (30 + 8 + 8 + 2 + 1 + 1) + int(math.log2(len(self.entries)))


class Unaliased:
    """Unbounded full-PC counter dictionary, diagnostic only, not a candidate."""
    def __init__(self):
        self.table = {}

    def predict(self, pc, target):
        return self.table.get(pc, 1) >= 2

    def update(self, pc, target, taken):
        self.table[pc] = saturate(self.table.get(pc, 1), taken)

    def state_bits(self):
        return len(self.table) * 33


def configurations():
    configs = {}
    for entries in [16, 64, 128, 256]:
        configs[f'bimodal-{entries}'] = dict(kind='counter', entries=entries)
        configs[f'confident-{entries}'] = dict(kind='counter', entries=entries, threshold=3)
        for history in [2, 4, int(math.log2(entries))]:
            configs[f'gshare-{entries}-h{history}'] = dict(kind='counter', entries=entries, history_bits=history)
        history = int(math.log2(entries // 4))
        configs[f'bimode-{entries}-h{history}'] = dict(kind='bimode', entries=entries, history_bits=history)
    for entries in [4, 8]:
        configs[f'loop-{entries}'] = dict(kind='loop', entries=entries)
    configs['unaliased-diagnostic'] = dict(kind='unaliased')
    return configs


def predictor(config):
    options = dict(config)
    kind = options.pop('kind')
    return {'counter': CounterTable, 'bimode': BiMode, 'loop': LoopTable, 'unaliased': Unaliased}[kind](**options)


def alignment_configurations():
    # McFarling's original short-history variant XORs the history into the high
    # index bits. Compare it separately with the previously frozen low-bit sweep.
    configs = {'bimodal-64': dict(kind='counter', entries=64)}
    for entries in [16, 64, 128, 256]:
        width = int(math.log2(entries))
        for history in [2, 4]:
            if history < width:
                configs[f'gshare-high-{entries}-h{history}'] = dict(
                    kind='counter', entries=entries, history_bits=history, history_shift=width-history)
    return configs


def working_sets(records):
    # PC/context bias is computed after the full trace: descriptive information,
    # not an oracle result usable by an online predictor or a CPU speed estimate.
    result = {}
    for bits in [0, 4, 8, 16, 24]:
        contexts, history = {}, 0
        for pc, kind, taken, target, push, pop in records:
            if kind != 0:
                continue
            values = contexts.setdefault((pc, history), [0, 0])
            values[int(taken)] += 1
            history = ((history << 1) | taken) & ((1 << bits) - 1)
        ordered = sorted(contexts.values(), key=sum, reverse=True)
        total, covered, biased, count = sum(map(sum, ordered)), 0, 0, 0
        for values in ordered:
            covered += sum(values)
            biased += max(values)
            count += 1
            if covered >= total * .95:
                break
        result[str(bits)] = dict(unique_contexts=len(contexts), working_set_95=count,
                                 covered_branches=covered, conditional_branches=total,
                                 retrospective_bias=biased / covered if covered else None)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--alignment-only', action='store_true', help='Additional short-history high-bit XOR study')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    configs = alignment_configurations() if args.alignment_only else configurations()
    output = {'scope': 'cold resolved-order direction screening; no pipeline, wrong path or CPU timing',
              'btb_policy': 'taken admission, round robin; fixed two ways and RAS4',
              'configs': configs, 'cases': {}, 'working_sets': {}, 'traces': {}}
    cases = json.loads((args.root / 'images/manifest.json').read_text())['cases']
    for case in cases:
        if case['held']:
            continue
        trace = args.root / 'rtl/dev-720/B0' / (case['name'] + '.trace')
        raw = trace.read_bytes()
        records, instructions = [], 0
        for line in raw.decode().splitlines():
            pc, insn, nxt, cycle = line.split(',')
            record = decode(int(pc, 16), int(insn, 16), int(nxt, 16))
            instructions += 1
            if record:
                records.append(record)
        output['traces'][case['name']] = hashlib.sha256(raw).hexdigest()
        output['working_sets'][case['name']] = working_sets(records)
        rows = {}
        for btb in [16, 32]:
            target = dict(bht=64, btb=btb, ways=2, ras=4, policy='taken')
            for name, config in configs.items():
                direction = predictor(config)
                row = evaluate(records, instructions, target, direction)
                row['direction_state_bits'] = direction.state_bits()
                if isinstance(direction, LoopTable):
                    row['loop_overrides'] = direction.overrides
                rows[f'btb{btb}-{name}'] = row
        output['cases'][case['name']] = rows
        print('DIRECTION', case['name'], flush=True)
    output['summary'] = {}
    for btb in [16, 32]:
        for name in configs:
            key, baseline = f'btb{btb}-{name}', f'btb{btb}-bimodal-64'
            ratios = [rows[key]['counts']['errors'] / rows[baseline]['counts']['errors']
                      for rows in output['cases'].values()]
            output['summary'][key] = {'error_ratio_gm': math.prod(ratios) ** (1 / len(ratios)),
                                      'max_error_ratio': max(ratios),
                                      'direction_state_bits': next(iter(output['cases'].values()))[key]['direction_state_bits']}
    (args.output / 'results.json').write_text(json.dumps(output, indent=2) + '\n')
    for name, row in sorted(output['summary'].items(), key=lambda item: item[1]['error_ratio_gm']):
        print(name, f"{row['error_ratio_gm']:.4f}", row['direction_state_bits'], flush=True)


if __name__ == '__main__':
    main()
