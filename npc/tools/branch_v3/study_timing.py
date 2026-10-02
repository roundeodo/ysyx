#!/usr/bin/env python3
"""Fixed-event timing diagnostics. These opportunities are NOT saved CPU cycles."""
import collections
import hashlib
import json
from pathlib import Path
from trace_io import event_files, open_text, sha_uncompressed

from targets import TargetTable

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC / 'result/branch-v3'


def main():
    records = []
    for path in sorted(event_files(ROOT / 'rtl/B0-opportunity')):
        queries, accepts, operands, retired, resolved = {}, {}, {}, {}, {}
        for line in open_text(path):
            row = line.strip().split(',')
            if row[0] == 'Q':
                queries[int(row[1])] = row
            elif row[0] == 'A':
                accepts[int(row[1])] = row
            elif row[0] == 'C':
                retired[int(row[1])] = row
            elif row[0] == 'R':
                resolved[int(row[1])] = row
            elif row[0] == 'O':
                identity = int(row[1])
                state = operands.setdefault(identity, {'first': int(row[2]), 'ready': None,
                                                       'raw_wait': 0, 'structural_wait': 0,
                                                       'forwarded': False})
                state['raw_wait'] += int(row[4])
                state['structural_wait'] += int(row[5])
                if not int(row[4]) and state['ready'] is None:
                    state['ready'] = int(row[2])
                    state['forwarded'] = bool(int(row[7]) or int(row[8]))
        counts, gaps = collections.Counter(), collections.defaultdict(collections.Counter)
        events = []
        for identity, row in resolved.items():
            assert identity in retired and identity in accepts and identity in queries
            pc, target = int(row[3], 16), int(row[4], 16)
            kind, taken = int(row[5]), bool(int(row[6]))
            label = {1: 'branch', 2: 'jal', 3: 'jalr'}[kind]
            q, a = queries[identity], accepts[identity]
            counts[label] += 1
            counts[label + '_btb_absent'] += not int(q[4])
            counts[label + '_ex_redirect'] += int(row[10])
            gaps[label + '_fetch_to_resolve'][int(row[2])-int(a[2])] += 1
            if identity in operands:
                operand = operands[identity]
                counts[label + '_raw_wait_cycles'] += operand['raw_wait']
                counts[label + '_structural_wait_cycles'] += operand['structural_wait']
                if operand['ready'] is not None:
                    gaps[label + '_operand_ready_to_resolve'][int(row[2])-operand['ready']] += 1
                    counts[label + '_needs_forwarding'] += operand['forwarded']
            if taken:
                delta = (target-pc+2**31) % 2**32-2**31
                for width in (9, 13, 17, 21):
                    counts[f'taken_delta{width}_fits'] += -(1 << (width-1)) <= delta < (1 << (width-1))
                counts['taken_targets'] += 1
                counts['taken_cross_64KiB'] += (pc >> 16) != (target >> 16)
            events.extend([(int(q[2]), 0, identity), (int(row[2]), 1, identity)])
        # M1: replay each resolved branch's actual query/resolve times. No future
        # outcome enters lookup. Tables train only on its recorded resolution.
        # This excludes wrong-path queries and does not alter the PC stream.
        fast, slow = TargetTable(4), TargetTable(32)
        seen, pending = set(), set()
        tier = collections.Counter()
        for cycle, operation, identity in sorted(events):
            row = resolved[identity]
            pc, target, taken = int(row[3], 16), int(row[4], 16), bool(int(row[6]))
            if operation == 0:
                f, s = fast.lookup(pc), slow.lookup(pc)
                if f is None:
                    tier['fast_cold'] += pc not in seen and pc not in pending
                    tier['fast_unresolved_first'] += pc not in seen and pc in pending
                    tier['fast_replacement_or_conflict'] += pc in seen
                pending.add(pc)
                if taken and s == target and f != target:
                    tier['late_target_correct'] += 1
                    for latency in (1, 2, 3, 4):
                        tier[f'late{latency}_before_fetch_accept'] += cycle+latency < int(accepts[identity][2])
                        tier[f'late{latency}_before_resolve'] += cycle+latency < int(row[2])
                if taken and f == target and s is not None and s != target:
                    tier['harmful_slow_override'] += 1
            else:
                fast.train(pc, target)
                slow.train(pc, target)
                seen.add(pc)
                pending.discard(pc)
        records.append({'case': path.stem, 'source_sha256': sha_uncompressed(path),
                        'counts': dict(counts), 'gap_histograms': {key: dict(value) for key, value in gaps.items()},
                        'tier_fixed_event_M1': dict(tier)})
    document = {'scope': 'B0 development retired ROI branches; actual query/accept/resolve events',
                'limitations': ['M1 replays the baseline, not candidate wrong paths; no speedup estimate',
                                'Operand ready is existing RF/forwarding readiness, not a free extra read port',
                                'Fetch accept follows instruction availability and is conservative for predecode',
                                'Delta coverage is representability only; full PC tags and fallback still required',
                                'Tier tables start cold at ROI and use full tags, 2 ways, FIFO; no direction override'],
                'metadata_example_bits': {'type3_and_backward1_per_RV32I_slot_at_1KiB': 1024,
                                          'separate_valid_bit_per_slot_if_needed': 256},
                'records': records}
    (NPC / 'docs/research/branch-v3/timing-opportunities.json').write_text(json.dumps(document, indent=2)+'\n')
    print('PASS fixed-event target/readiness diagnostics', len(records))


if __name__ == '__main__':
    main()
