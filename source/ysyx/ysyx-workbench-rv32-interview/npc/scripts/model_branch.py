#!/usr/bin/env python3
"""Cold, retirement-order screening. No timing, wrong-path, or speculation claims."""
import argparse
from bisect import bisect_right
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import subprocess


def signed(value, width):
    return value - ((value >> (width - 1)) << width)


def decode(pc, instruction, next_pc):
    opcode = instruction & 127
    rd, rs1 = (instruction >> 7) & 31, (instruction >> 15) & 31
    if opcode == 0x63:
        imm = ((instruction >> 31) << 12 | ((instruction >> 7) & 1) << 11 |
               ((instruction >> 25) & 63) << 5 | ((instruction >> 8) & 15) << 1)
        return (pc, 0, next_pc != pc + 4, (pc + signed(imm, 13)) & 0xffffffff, False, False)
    if opcode == 0x6f:
        return (pc, 1, True, next_pc, rd in (1, 5), False)
    if opcode == 0x67:
        pop = rs1 in (1, 5) and (rd not in (1, 5) or rd != rs1) and instruction >> 20 == 0
        return (pc, 3 if pop else 2, True, next_pc, rd in (1, 5), pop)
    return None


def evaluate(records, instruction_count, config, direction=None, error_pc_limit=16):
    entries, ways, bht = config['btb'], config['ways'], config['bht']
    sets = entries // ways
    policy = config.get('policy', 'all')
    history_bits = config.get('history', 0)
    counters = [1] * bht
    # Entry fields: full PC, target, kind, RRPV, first-taken-reuse, insertion signature.
    table = [[None for _ in range(ways)] for _ in range(sets)]
    victim = [0] * sets
    stack, history = [], 0
    learning = [1] * 64
    stats = Counter()
    hot = Counter()
    for pc, kind, taken, target, push, pop in records:
        row = (pc >> 2) & (sets - 1)
        index = ((pc >> 2) ^ history) & (bht - 1)
        if not history_bits:
            index = (pc >> 2) & (bht - 1)
        direction_taken = counters[index] >= 2
        if direction is not None and kind == 0:
            direction_taken = direction.predict(pc, target)
        found = next((i for i, entry in enumerate(table[row]) if entry and entry[0] == pc), -1)
        predicted_taken = False
        predicted_target = 0
        if found >= 0:
            entry = table[row][found]
            predicted_taken = kind != 0 or direction_taken
            predicted_target = stack[-1] if kind == 3 and stack else entry[1]
        if config.get('ideal_direction') and found >= 0:
            predicted_taken = taken
        if config.get('ideal_btb'):
            predicted_taken = taken if config.get('ideal_direction') else kind != 0 or direction_taken
            predicted_target = stack[-1] if kind == 3 and stack else target
        actual_next = target if taken else pc + 4
        prediction_next = predicted_target if predicted_taken else pc + 4
        stats['branches'] += 1
        stats['conditional' if kind == 0 else 'returns' if kind == 3 else 'jumps'] += 1
        if found < 0:
            stats['btb_misses'] += 1
        if prediction_next != actual_next:
            stats['errors'] += 1
            hot[pc] += 1
            if found < 0 and not config.get('ideal_btb'):
                stats['missing_errors'] += 1
            elif predicted_taken != taken:
                stats['direction_errors'] += 1
            else:
                stats['target_errors'] += 1
            if kind == 0 and predicted_taken != taken:
                stats['false_taken' if predicted_taken else 'false_not_taken'] += 1
        if kind == 0:
            if direction is not None:
                direction.update(pc, target, taken)
            else:
                counters[index] = min(3, counters[index] + 1) if taken else max(0, counters[index] - 1)
                if history_bits:
                    history = ((history << 1) | taken) & ((1 << history_bits) - 1)
        # Admission control never suppresses BHT or RAS training.
        if policy == 'all' or found >= 0 or taken:
            if found >= 0:
                chosen = found
                entry = table[row][chosen]
                if taken:
                    entry[3] = 0
                    if not entry[4]:
                        learning[entry[5]] = min(3, learning[entry[5]] + 1)
                    entry[4] = True
                if policy in ('taken_lru', 'allhit_lru') and (taken or policy == 'allhit_lru'):
                    entry[3] = 0
                    for i, other in enumerate(table[row]):
                        if i != chosen and other:
                            other[3] += 1
            else:
                chosen = next((i for i, entry in enumerate(table[row]) if entry is None), -1)
                if chosen < 0:
                    stats['evictions'] += 1
                    if policy in ('taken_rrip', 'learned'):
                        maximum = max(entry[3] for entry in table[row])
                        chosen = next(i for i, entry in enumerate(table[row]) if entry[3] == maximum)
                        for entry in table[row]:
                            entry[3] += 3 - maximum
                    elif policy in ('taken_lru', 'allhit_lru'):
                        chosen = max(range(ways), key=lambda i: table[row][i][3])
                    else:
                        chosen = victim[row]
                        victim[row] = (chosen + 1) % ways
                    old = table[row][chosen]
                    if not old[4]:
                        stats['unused_victims'] += 1
                        learning[old[5]] = max(0, learning[old[5]] - 1)
                signature = ((pc >> 2) ^ (pc >> 8)) & 63
                insertion = 3 if policy == 'learned' and learning[signature] == 0 else 2
                if policy in ('taken_lru', 'allhit_lru'):
                    for entry in table[row]:
                        if entry:
                            entry[3] += 1
                    insertion = 0
                table[row][chosen] = [pc, target, kind, insertion, False, signature]
                stats['allocations'] += 1
                if not taken:
                    stats['not_taken_allocations'] += 1
            table[row][chosen][1:3] = [target, kind]
        else:
            stats['suppressed_allocations'] += 1
        if pop and stack:
            stack.pop()
        if push and config['ras']:
            stack.append((pc + 4) & 0xffffffff)
            stack = stack[-config['ras']:]
    tag_bits = 30 - int(math.log2(sets))
    # Logical state only: excludes query/response registers and combinational
    # gates. Actual synthesized whole-core area is the selection criterion.
    bits = entries * (tag_bits + 32 + 2 + 1) + bht * 2 + history_bits
    if direction is not None:
        bits += direction.state_bits() - bht * 2 - history_bits
    if policy in ('all', 'taken'):
        bits += sets * int(math.log2(ways))
    elif policy in ('taken_lru', 'allhit_lru'):
        bits += sets * math.ceil(math.log2(math.factorial(ways)))
    if config['ras']:
        bits += config['ras'] * 32 + int(math.log2(config['ras'])) + math.ceil(math.log2(config['ras'] + 1))
    if policy in ('taken_rrip', 'learned'):
        bits += 2 * entries
    if policy == 'learned':
        bits += entries * 7 + 128
    return {'counts': dict(stats), 'mpki': 1000 * stats['errors'] / instruction_count,
            'state_bits_estimate': bits, 'hot_error_pc': hot.most_common(error_pc_limit)}


def configurations():
    base = {'bht': 16, 'btb': 16, 'ways': 2, 'ras': 4, 'policy': 'all'}
    configs = {'B0': base}
    for btb in [16, 32, 64, 128]:
        for bht in [16, 64, 256]:
            configs[f'b{btb}h{bht}'] = dict(base, btb=btb, bht=bht)
        for policy in ['taken', 'taken_lru', 'allhit_lru', 'taken_rrip', 'learned']:
            configs[f'b{btb}-{policy}'] = dict(base, btb=btb, bht=64, policy=policy)
    for history in [2, 4, 6, 8]:
        configs[f'gshare-{history}'] = dict(base, btb=64, bht=256, history=history)
    for ways in [1, 4]:
        configs[f'b64ways{ways}'] = dict(base, btb=64, bht=64, ways=ways)
    for ras in [8, 16]:
        configs[f'b64ras{ras}'] = dict(base, btb=64, bht=64, ras=ras)
    configs['ideal-direction'] = dict(base, ideal_direction=True)
    configs['ideal-btb'] = dict(base, ideal_btb=True)
    configs['ideal-both'] = dict(base, ideal_direction=True, ideal_btb=True)
    return configs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    out = args.output.resolve() if args.output else root / 'model'
    out.mkdir(exist_ok=False)
    configs = configurations()
    (out / 'configurations.json').write_text(json.dumps(configs, indent=2) + '\n')
    cases = json.loads((root / 'images/manifest.json').read_text())['cases']
    all_results, diagnostics = {}, {}
    for case in cases:
        if case['held']:
            continue
        trace = root / 'rtl/dev-720/B0' / (case['name'] + '.trace')
        records, total = [], 0
        pc_counts = Counter()
        for line in trace.read_text().splitlines():
            pc, insn, nxt, cycle = line.split(',')
            total += 1
            record = decode(int(pc, 16), int(insn, 16), int(nxt, 16))
            if record:
                records.append(record)
                pc_counts[record[0]] += 1
        symbols = []
        for line in subprocess.check_output(['riscv64-linux-gnu-nm', '-n', str(root / 'images' / case['name'] / 'image.elf')], text=True).splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[1] in ('t', 'T'):
                symbols.append((int(parts[0], 16), parts[2]))
        addresses = [pc for pc, name in symbols]
        by_function = Counter()
        for pc, count in pc_counts.items():
            index = bisect_right(addresses, pc) - 1
            by_function[symbols[index][1] if index >= 0 else 'unknown'] += count
        diagnostics[case['name']] = {
            'trace_sha256': hashlib.sha256(trace.read_bytes()).hexdigest(),
            'instructions': total, 'branches': len(records), 'static_branches': len(pc_counts),
            'functions': by_function.most_common(),
            'ambiguous_pc_plus_four_branches': sum(kind == 0 and target == pc + 4 for pc, kind, taken, target, push, pop in records)}
        all_results[case['name']] = {name: evaluate(records, total, config) for name, config in configs.items()}
        print('MODEL', case['name'], len(records), flush=True)
    summary = {}
    for name in configs:
        ratios = [rows[name]['counts'].get('errors', 0) / rows['B0']['counts']['errors'] for rows in all_results.values()]
        summary[name] = {'error_ratio_gm': math.prod(ratios) ** (1 / len(ratios)),
                         'state_bits_estimate': next(iter(all_results.values()))[name]['state_bits_estimate']}
    result = {'scope': 'cold retirement-order diagnostic; zero training delay; no CPU timing',
              'configs': configs, 'diagnostics': diagnostics, 'cases': all_results, 'summary': summary}
    (out / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    for name, row in sorted(summary.items(), key=lambda item: item[1]['error_ratio_gm']):
        print(name, f"{row['error_ratio_gm']:.4f}", row['state_bits_estimate'], flush=True)


if __name__ == '__main__':
    main()
