#!/usr/bin/env python3
"""Align retired control flow by architectural order, not absolute clock or query ID."""
import collections
import json
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC/'result/branch-v3/rtl'


def branches(path):
    results = []
    early = {}
    for line in path.open():
        row = line.strip().split(',')
        if row[0] == 'E':
            early[int(row[1])] = int(row[3], 16)
        if row[0] == 'R':
            pc, target = int(row[3], 16), int(row[4], 16)
            kind, taken = int(row[5]), bool(int(row[6]))
            adopted = early.get(int(row[1]))
            results.append({'identity': (pc, target, kind, taken),
                            'raw_correct': bool(int(row[7])) == taken,
                            'btb_hit': bool(int(row[8])), 'late_redirect': bool(int(row[10])),
                            'early': adopted is not None,
                            'early_correct': adopted == (target if taken else (pc+4)&0xffffffff)})
    return results


def main():
    records = []
    baseline = {path.stem: branches(path) for path in (ROOT/'B0').glob('*.events')}
    for name in ['S','H2-narrow-v2','E0','H2E-narrow','N0','NL','NS','NSL',
                 'N0E','N0-spec-final','R0-held','ER0-held','NER0-held','NSmallER-held']:
        source = ROOT.parent/'snapshots'/name/'tests/core_tb.sv'
        early_logged = source.exists() and '"E,' in source.read_text()
        for path in sorted((ROOT/name).glob('*.events')):
            actual, reference = branches(path), baseline[path.stem]
            assert len(actual) == len(reference), (name, path.stem, 'window mismatch')
            counts, sites = collections.Counter(), collections.defaultdict(collections.Counter)
            for candidate, old in zip(actual, reference):
                assert candidate['identity'] == old['identity'], (name, path.stem, 'branch sequence mismatch')
                pc, target, kind, taken = candidate['identity']
                label = {1:'conditional',2:'jal',3:'jalr'}[kind]
                counts[label] += 1
                counts[label+'_late_redirect'] += candidate['late_redirect']
                counts[label+'_late_helpful'] += old['late_redirect'] and not candidate['late_redirect']
                counts[label+'_late_harmful'] += not old['late_redirect'] and candidate['late_redirect']
                if early_logged:
                    counts[label+'_early'] += candidate['early']
                    counts[label+'_early_correct'] += candidate['early_correct']
                if kind == 1:
                    key = f"btb{int(candidate['btb_hit'])}_raw{int(candidate['raw_correct'])}_nextpc{1-int(candidate['late_redirect'])}"
                    counts[key] += 1
                    if old['late_redirect'] != candidate['late_redirect']:
                        sites[hex(pc)]['helpful' if old['late_redirect'] else 'harmful'] += 1
            records.append({'candidate': name, 'case': path.stem, 'early_events_available': early_logged,
                            'counts': dict(counts),
                            'conditional_sites': dict(sites)})
    (NPC/'docs/research/branch-v3/disagreements.json').write_text(json.dumps({
        'scope':'Actual R events aligned by architectural branch order; paired retired traces checked separately',
        'limits':'Late correction removed does not equal cycles saved; early overrides may still be wrong',
        'records':records}, indent=2)+'\n')
    print('PASS architectural branch alignment', len(records))


if __name__ == '__main__':
    main()
