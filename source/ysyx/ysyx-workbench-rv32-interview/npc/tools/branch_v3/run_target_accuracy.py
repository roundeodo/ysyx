#!/usr/bin/env python3
"""Fixed-event models for predecode/prefill, tiers, regions and compact targets."""
import argparse
import collections
from concurrent.futures import ProcessPoolExecutor
import hashlib
import itertools
import json
from pathlib import Path
import re

from models import Hybrid, ScaledTage
from target_models import Btb, Metadata, Prefill, decode
from trace_io import event_files, open_text, sha_uncompressed

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC / 'result/branch-v3'
DOCS = NPC / 'docs/research/branch-v3'
PAIRS = [('B0-victim-dev', 'B0-target-model-20261002-dev'),
         ('B0-victim-stream-dev-700', 'B0-target-model-20261002-streams')]
CONFIGS = {
    'full16': {'entries': 16, 'ways': 2, 'index': 0, 'policy': 0, 'admission': 1},
    'full32': {}, 'full64': {'entries': 64},
    'predecode_type': {}, 'predecode_direct': {},
    'prefill_all': {}, 'prefill_backward': {},
    'tier4_32_L1': {}, 'tier4_32_L2': {}, 'tier4_32_L3': {},
    'region32_r2': {'regions': 2}, 'region32_r4': {'regions': 4},
    'region32_r4_L2': {'regions': 4}, 'region64_r4': {'entries': 64, 'regions': 4},
    'compact32_U16': {'widths': [16, 16, 16, 16]},
    'compact32_mixed': {'widths': [12, 16, 24, 32]},
    'compact64_U16': {'entries': 64, 'widths': [16, 16, 16, 16]},
    'compact64_mixed': {'entries': 64, 'widths': [12, 16, 24, 32]},
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def observations(path):
    return [line for line in path.read_text().splitlines()
            if line.startswith(('RESULT ', 'COUNTERS ', 'DETAIL '))]


def choose(pc, entry, direction, ras):
    if entry is None:
        return (pc + 4) & 0xffffffff, None
    target, kind = entry
    if kind == 3 and ras:
        target = ras[-1]
    taken = direction if kind == 0 else True
    return (target if taken else (pc + 4) & 0xffffffff), target


def run_case(item):
    old, new, case = item
    path = ROOT / 'rtl' / old / (case + '.events')
    metadata_path = ROOT / 'rtl' / new / (case + '.metadata')
    old_log = ROOT / 'rtl' / old / (case + '.log')
    new_log = ROOT / 'rtl' / new / (case + '.log')
    assert observations(old_log) == observations(new_log), (case, 'metadata observer changed execution')
    index = json.loads((ROOT / 'rtl' / old / 'index.json').read_text())
    recorded = next(row for row in index if row['name'] == case)
    assert digest(old_log) == recorded['log_sha256']
    image_path = next(Path(arg[7:]).with_name('image.bin') for arg in recorded['command']
                      if arg.startswith('+image='))
    image = image_path.read_bytes()
    roi, trained, accepts = {}, set(), {}
    with open_text(path) as stream:
        for line in stream:
            row = line.rstrip().split(',')
            if row[0] == 'R':
                roi[int(row[1])] = row
            elif row[0] == 'F':
                trained.add(int(row[1]))
            elif row[0] == 'A':
                accepts[int(row[1])] = int(row[2])
            elif row[0] == 'C':
                offset = int(row[3], 16) - 0x80000000
                assert 0 <= offset <= len(image) - 4
                word = int.from_bytes(image[offset:offset+4], 'little')
                assert word == int(row[4], 16), 'Workload has modified instruction memory'
                assert (word & 0x707f) != 0x100f, 'FENCE.I needs separate recovery inputs'
    tables = {name: Btb(**config) for name, config in CONFIGS.items()}
    fast = Btb(entries=4, ways=2, index=0, policy=0, admission=1)
    prefill = {'prefill_all': Prefill(), 'prefill_backward': Prefill(True)}
    for name, value in prefill.items():
        tables[name] = value.table
    directions = {'BHT16': Hybrid(), 'TAGE': ScaledTage(),
                  'TAGE_SC_Loop': ScaledTage(sc=True, loop=True)}
    metadata = Metadata()
    ras, pending = [], {}
    counts = collections.defaultdict(collections.Counter)
    metadata_stream = iter(metadata_path.read_text().splitlines())
    next_metadata = next(metadata_stream, None)
    current_cycle, execution_write = None, False
    query_checks = 0

    def finish_edge(cycle, busy):
        nonlocal next_metadata
        if not busy:
            for model in prefill.values():
                model.tick()
        events = []
        while next_metadata is not None and int(next_metadata.split(',')[1]) == cycle:
            events.append(next_metadata.split(','))
            next_metadata = next(metadata_stream, None)
        if events:
            if any(row[0] == 'V' for row in events):
                for table in tables.values():
                    table.clear()
                fast.clear()
                for model in prefill.values():
                    model.clear()
                for direction in directions.values():
                    direction.invalidate()
                ras.clear()
            installs = metadata.apply(events)
            for model in prefill.values():
                model.enqueue(installs)

    with open_text(path) as stream:
        for line in stream:
            fields = line.rstrip().split(',')
            if fields[0] not in ('Q', 'F'):
                continue
            cycle = int(fields[2])
            if current_cycle is not None and cycle != current_cycle:
                finish_edge(current_cycle, execution_write)
                # Process refill clocks that had no query or execution event.
                while next_metadata is not None and int(next_metadata.split(',')[1]) < cycle:
                    mc = int(next_metadata.split(',')[1])
                    assert mc > current_cycle
                    for model in prefill.values():
                        model.tick(mc - current_cycle - 1)
                    finish_edge(mc, False)
                    current_cycle = mc
                for model in prefill.values():
                    model.tick(cycle - current_cycle - 1)
            if cycle != current_cycle:
                current_cycle, execution_write = cycle, False
            identity, pc = int(fields[1]), int(fields[3], 16)
            if fields[0] == 'Q':
                observed = tables['full16'].lookup(pc)
                assert bool(observed) == bool(int(fields[4])), (case, cycle, 'baseline hit')
                if observed is not None:
                    assert observed == (int(fields[8], 16), int(fields[7])), (case, cycle, 'baseline target/kind')
                bht = directions['BHT16'].lookup(pc)
                assert bht.counter == int(fields[10], 16), (case, cycle, 'baseline BHT')
                query_checks += 1
                if identity not in trained:
                    continue
                contexts = {name: model.lookup(pc) for name, model in directions.items()}
                entries = {name: table.lookup(pc) for name, table in tables.items()}
                fast_entry, cached = fast.lookup(pc), metadata.lookup(pc)
                forecasts = {}
                for dname, context in contexts.items():
                    direction = context.prediction if dname == 'BHT16' else context['prediction']
                    for name in CONFIGS:
                        entry, latency, late = entries[name], 1, None
                        if name.startswith('tier'):
                            latency = int(name[-1])
                            late = entry if entry is not None else fast_entry
                            entry = fast_entry
                        elif name.endswith('_L2'):
                            latency, late, entry = 2, entry, None
                        elif name.startswith('predecode') and cached is not None:
                            kind, direct, _ = cached
                            if kind is None:
                                entry = None
                            elif name == 'predecode_direct' and direct is not None:
                                entry = (direct, kind)
                            elif kind == 3 and ras:
                                entry = (ras[-1], 3)
                            elif entry is not None:
                                entry = (entry[0], kind)
                        initial, target = choose(pc, entry, direction, ras)
                        late_guess, late_target = choose(pc, late, direction, ras)
                        forecasts[dname, name] = (initial, target, late_guess, late_target, latency)
                pending[identity] = (cycle, contexts, forecasts)
                continue
            execution_write = True
            target, kind, taken = int(fields[4], 16), int(fields[5]) - 1, bool(int(fields[6]))
            offset = pc - 0x80000000
            word = int.from_bytes(image[offset:offset+4], 'little')
            decoded_kind, direct, immediate = decode(pc, word)
            assert decoded_kind is not None
            assert (kind == 0 and decoded_kind == 0) or (kind == 1 and decoded_kind == 1) or kind == 2
            if direct is not None:
                assert direct == target, (case, 'decoded direct target')
            query_cycle, contexts, forecasts = pending.pop(identity)
            if identity in roi:
                r = roi[identity]
                assert int(r[3], 16) == pc and int(r[4], 16) == target and int(r[6]) == int(taken)
                actual_next = target if taken else (pc + 4) & 0xffffffff
                for (dname, name), (initial, guess_target, late, late_target, latency) in forecasts.items():
                    count = counts[dname + '/' + name]
                    fetch_guess = late if (name.startswith('tier') or name.endswith('_L2')) and query_cycle+latency < accepts[identity] else initial
                    ex_guess = late if (name.startswith('tier') or name.endswith('_L2')) and query_cycle+latency < cycle else initial
                    count['branches'] += 1
                    count['initial_next_pc_errors'] += initial != actual_next
                    count['before_fetch_next_pc_errors'] += fetch_guess != actual_next
                    count['before_EX_next_pc_errors'] += ex_guess != actual_next
                    if kind == 0:
                        context = contexts[dname]
                        raw = context.prediction if dname == 'BHT16' else context['prediction']
                        count['conditional'] += 1
                        count['raw_direction_errors'] += raw != taken
                    if taken:
                        count['taken'] += 1
                        count['initial_target_absent'] += guess_target is None
                        count['initial_target_wrong'] += guess_target is not None and guess_target != target
                        count['initial_target_correct'] += guess_target == target
            for dname, model in directions.items():
                if kind == 0:
                    model.train(contexts[dname], taken)
            for table in tables.values():
                table.train(pc, target, decoded_kind, taken)
            fast.train(pc, target, decoded_kind, taken)
            rd, rs1 = (word >> 7) & 31, (word >> 15) & 31
            pop = kind == 2 and rs1 in (1, 5) and (rd not in (1, 5) or rd != rs1) and immediate == 0
            push = kind in (1, 2) and rd in (1, 5)
            if taken:
                if pop and ras:
                    ras.pop()
                if push:
                    if len(ras) == 4:
                        ras.pop(0)
                    ras.append((pc + 4) & 0xffffffff)
    assert not pending
    raw = sum(int(re.search(r'conditional_errors=(\d+)', x)[1]) + int(re.search(r'target_errors=(\d+)', x)[1])
              for x in observations(old_log) if x.startswith('COUNTERS '))
    assert counts['BHT16/full16']['initial_next_pc_errors'] == raw, (case, 'baseline redirect count')
    return {'case': case, 'family': case.split('-dev-')[0] if '-dev-' in case else case.split('_')[0],
            'query_checks': query_checks, 'image_sha256': digest(image_path),
            'events_sha256_uncompressed': sha_uncompressed(path),
            'metadata_sha256': digest(metadata_path), 'metadata_execution_equivalence': True,
            'counts': {name: dict(value) for name, value in counts.items()},
            'target_state_bits': {name: table.bits for name, table in tables.items()},
            'prefill': {name: {'write_attempts': model.writes, 'dropped': model.dropped}
                        for name, model in prefill.items()},
            'region_evictions': {name: table.region_evictions for name, table in tables.items()},
            'compact_rejections': {name: table.rejected for name, table in tables.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--case', action='append')
    args = parser.parse_args()
    records = []
    jobs = [(old, new, path.stem) for old, new in PAIRS
            for path in event_files(ROOT / 'rtl' / old)
            if not args.case or path.stem in args.case]
    output = ROOT / 'target-accuracy-20261002'
    output.mkdir(exist_ok=True)
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        for record in pool.map(run_case, jobs):
            records.append(record)
            (output / (record['case'] + '.json')).write_text(json.dumps(record, indent=2) + '\n')
            print('PASS target models', record['case'], record['query_checks'], 'baseline queries', flush=True)
    aggregates = collections.defaultdict(collections.Counter)
    for record in records:
        for name, values in record['counts'].items():
            aggregates[name].update(values)
    report = {'scope': 'Development only, full natural prefix, fixed actual baseline query/resolve/cache-write timing; no train or holdout.',
              'model_configs': CONFIGS, 'records': records,
              'counts': {name: dict(value) for name, value in aggregates.items()},
              'limits': ['No candidate-specific wrong path, history timing or cache replacements are regenerated; not CPU speed or PPA.',
                         'Targets use full PC identity; model state bits are logical estimates, not mapped area.',
                         'Predecode direct stores 3-bit type plus 21-bit direct displacement per instruction (6144 bits), with separate query-side cache identity/ports requiring implementation.',
                         'Prefill starts only after actual complete line install; four hints, one idle write/clock; execution training has priority. It never trains direction or RAS.',
                         'Tiers add a fast 4-entry RR/all table to a 32-entry fold/SRRIP/taken table; latency is explicitly one to three cycles. Capacity total is 36, not 32.',
                         'Regions share 16 high target bits across 2/4 region entries and invalidate users before region replacement; L2 is a latency sensitivity point.',
                         'Compact U16 or per-way 12/16/24/32 has range checks and safe migration/rejection; new index/replacement combinations are model prototypes, not delivered RTL.',
                         'All target candidates share each resolved direction model and RAS4; raw direction errors cannot change in this fixed-event isolation experiment.'],
              'source_sha256': {file.name: digest(file) for file in (Path(__file__), Path(__file__).with_name('target_models.py'), Path(__file__).with_name('models.py'))}}
    (DOCS / 'target-accuracy-models.json').write_text(json.dumps(report, indent=2) + '\n')
    print('COMPLETE', len(records), 'inputs', len(CONFIGS) * 3, 'joint configurations', flush=True)


if __name__ == '__main__':
    main()
