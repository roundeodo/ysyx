#!/usr/bin/env python3
"""Replay frozen baseline events through a broader finite BTB policy matrix."""
import argparse
import csv
from concurrent.futures import ProcessPoolExecutor
import gzip
import hashlib
import heapq
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess

from models import Hybrid, ScaledTage
from target_models import decode
from trace_io import event_files, open_text, sha_uncompressed

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC / 'result/branch-v3'
DOCS = NPC / 'docs/research/branch-v3'
OUT = ROOT / 'btb-replacement-20261002'
CONTRACT = DOCS / 'btb-replacement-contract.json'
EVENT = struct.Struct('<14I')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_case(job):
    old, metadata_label, case = job
    source = ROOT / 'rtl' / old / (case + '.events')
    cache_writes = ROOT / 'rtl' / metadata_label / (case + '.metadata')
    earlier = json.loads((DOCS / 'target-accuracy-models.json').read_text())
    identity = next(row for row in earlier['records'] if row['case'] == case)
    index = json.loads((ROOT / 'rtl' / old / 'index.json').read_text())
    invocation = next(row for row in index if row['name'] == case)
    log = ROOT / 'rtl' / old / (case + '.log')
    assert sha(log) == invocation['log_sha256']
    image_path = next(Path(arg[7:]).with_name('image.bin') for arg in invocation['command'] if arg.startswith('+image='))
    image = image_path.read_bytes()
    assert sha(image_path) == identity['image_sha256']
    assert sha(cache_writes) == identity['metadata_sha256']
    roi, trained = set(), set()
    retired_count = 0
    with open_text(source) as stream:
        for line in stream:
            row = line.rstrip().split(',')
            if row[0] == 'F':
                trained.add(int(row[1]))
            elif row[0] == 'R':
                roi.add(int(row[1]))
            elif row[0] == 'C':
                offset = int(row[3], 16) - 0x80000000
                assert 0 <= offset <= len(image) - 4
                word = int.from_bytes(image[offset:offset + 4], 'little')
                assert word == int(row[4], 16) and word & 0x707f != 0x100f
                retired_count += 1
    assert sha_uncompressed(source) == identity['events_sha256_uncompressed']

    def trace_events():
        directions = [Hybrid(), ScaledTage(), ScaledTage(sc=True, loop=True)]
        pending = {}
        last_resolution = None
        with open_text(source) as stream:
            for line in stream:
                row = line.rstrip().split(',')
                operation = row[0]
                if operation not in ('Q', 'F', 'C', 'S'):
                    continue
                event = [0] * 14
                if operation == 'S':
                    cycle = int(row[1])
                    assert last_resolution is not None and last_resolution[0] == cycle
                    event[0:3] = [7, last_resolution[1], cycle]
                    yield event
                    continue
                identity, cycle, pc = int(row[1]), int(row[2]), int(row[3], 16)
                event[1:4] = [identity, cycle, pc]
                if operation == 'Q':
                    context = directions[0].lookup(pc)
                    assert context.counter == int(row[10], 16)
                    event[8:11] = [int(row[4]), int(row[8], 16), int(row[7])]
                    event[11] = int(context.prediction)
                    if identity in trained:
                        contexts = [context, directions[1].lookup(pc), directions[2].lookup(pc)]
                        event[11] |= int(contexts[1]['prediction']) << 1 | int(contexts[2]['prediction']) << 2
                        event[12] = 1
                        pending[identity] = contexts
                    yield event
                elif operation == 'F':
                    target, actual_kind, taken = int(row[4], 16), int(row[5]) - 1, int(row[6])
                    offset = pc - 0x80000000
                    word = int.from_bytes(image[offset:offset + 4], 'little')
                    kind, direct, immediate = decode(pc, word)
                    assert kind is not None and (actual_kind == 2 or actual_kind == kind)
                    if direct is not None:
                        assert direct == target
                    event[0] = 1
                    event[4:8] = [target, kind, taken, int(identity in roi)]
                    rd, rs1 = (word >> 7) & 31, (word >> 15) & 31
                    pop = actual_kind == 2 and rs1 in (1, 5) and (rd not in (1, 5) or rd != rs1) and immediate == 0
                    push = actual_kind in (1, 2) and rd in (1, 5)
                    event[13] = int(pop) | int(push) << 1
                    contexts = pending.pop(identity)
                    if kind == 0:
                        for model, context in zip(directions, contexts):
                            model.train(context, bool(taken))
                    last_resolution = (cycle, identity)
                    yield event
                elif identity in trained:
                    event[0] = 2
                    yield event
        assert not pending

    def metadata_events():
        for line in cache_writes.read_text().splitlines():
            row = line.split(',')
            event = [0] * 14
            event[2] = int(row[1])
            if row[0] == 'V':
                event[0] = 6
            else:
                event[1], event[4] = int(row[2]), int(row[3])
                event[3] = int(row[5], 16)
                if row[0] == 'D':
                    event[0], event[5] = 4, int(row[4])
                else:
                    event[0] = 5 if row[4] == '1' else 3
            yield event

    binary = OUT / (case + '.bin')
    with binary.open('wb') as output:
        for event in heapq.merge(trace_events(), metadata_events(), key=lambda e: e[2]):
            output.write(EVENT.pack(*event))
    command = [str(OUT / 'screen'), str(OUT / 'configs.csv'), str(binary)]
    run = subprocess.run(command, capture_output=True, text=True)
    (OUT / (case + '.stderr')).write_text(run.stderr)
    if run.returncode:
        raise RuntimeError(f'{case}: native finite models failed: {run.stderr}')
    (OUT / (case + '.csv')).write_text(run.stdout)
    rows = [dict((name, int(value)) for name, value in row.items()) for row in csv.DictReader(run.stdout.splitlines())]
    contract = json.loads(CONTRACT.read_text())
    assert len(rows) == len(contract['configs'])
    configurations = {cfg['name']: rows[i] for i, cfg in enumerate(contract['configs'])}
    baseline = configurations['full16_all/rr/none/BHT16']
    counters = next(line for line in log.read_text().splitlines() if line.startswith('COUNTERS '))
    expected = int(re.search(r'conditional_errors=(\d+)', counters)[1]) + int(re.search(r'target_errors=(\d+)', counters)[1])
    assert baseline['next_pc_errors'] == expected
    # Independent prior Python model provides cross-language joint controls.
    for topology, previous in [('full16_all', 'full16'), ('full32', 'full32'), ('full64', 'full64'), ('compact32', 'compact32_U16')]:
        policy = 'rr' if topology == 'full16_all' else 'srrip'
        for direction in ['BHT16', 'TAGE', 'TAGE_SC_Loop']:
            now = configurations[f'{topology}/{policy}/none/{direction}']
            old_count = identity['counts'][f'{direction}/{previous}']
            assert now['next_pc_errors'] == old_count['initial_next_pc_errors'], (case, topology, direction)
            assert now['direction_errors'] == old_count['raw_direction_errors']
            assert now['target_absent'] == old_count['initial_target_absent']
            assert now['target_wrong'] == old_count['initial_target_wrong']
    for prefill, previous in [('all', 'prefill_all'), ('backward', 'prefill_backward')]:
        for direction in ['BHT16', 'TAGE', 'TAGE_SC_Loop']:
            now = configurations[f'full32/srrip/{prefill}/{direction}']
            old_count = identity['counts'][f'{direction}/{previous}']
            assert now['next_pc_errors'] == old_count['initial_next_pc_errors'], (case, prefill, direction)
            assert now['hint_attempts'] == identity['prefill'][previous]['write_attempts']
            assert now['hint_dropped'] == identity['prefill'][previous]['dropped']
    digest = sha(binary)
    compressed = binary.with_suffix('.bin.gz')
    with binary.open('rb') as source_stream, gzip.open(compressed, 'wb', compresslevel=1) as dest:
        shutil.copyfileobj(source_stream, dest)
    with gzip.open(compressed, 'rb') as stream:
        verify = hashlib.sha256()
        for block in iter(lambda: stream.read(1 << 20), b''):
            verify.update(block)
    assert verify.hexdigest() == digest
    binary.unlink()  # Preserve the same complete derived input losslessly.
    record = {'case': case, 'family': identity['family'], 'baseline_query_checks': baseline['query_checks'],
              'full_prefix_retired': retired_count, 'source_identity': {key: identity[key] for key in ['image_sha256', 'events_sha256_uncompressed', 'metadata_sha256']},
              'command': command, 'derived_input_sha256': digest, 'derived_input_compressed_sha256': sha(compressed),
              'native_binary_sha256': sha(OUT / 'screen'), 'counts': rows,
              'checks': {'RTL_baseline_queries': True, 'RTL_baseline_redirect_count': True, 'independent_Python_joint_controls': 18}}
    (OUT / (case + '.json')).write_text(json.dumps(record, indent=2) + '\n')
    print('PASS broader policies', case, '420 configs;', baseline['query_checks'], 'RTL queries; 18 joint controls', flush=True)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--case', action='append')
    args = parser.parse_args()
    source = Path(__file__).with_name('screen_replacement.cpp')
    build = ['g++', '-std=c++17', '-O3', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(OUT / 'screen')]
    subprocess.run(build, check=True)
    contract = json.loads(CONTRACT.read_text())
    jobs = [(old, meta, path.stem) for old, meta in contract['input_pairs']
            for path in event_files(ROOT / 'rtl' / old) if not args.case or path.stem in args.case]
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        records = list(pool.map(run_case, jobs))
    result = {'contract_sha256': sha(CONTRACT), 'build_command': build, 'records': records,
              'source_sha256': {p.name: sha(p) for p in [Path(__file__), source, source.with_name('replacement_btb.h'), source.with_name('models.py')]},
              'scope': contract['scope'], 'limits': ['Fixed baseline query/resolve/cache residence. No regenerated candidate wrong paths, performance or PPA.',
                  'Retirement feedback uses actual full-prefix C identities, finite four-bit generation and EX-priority write port. Cancelled snapshots are evaluator bookkeeping, not new hardware capacity.',
                  'DIP/DRRIP have only one leader set each in a 4/8/16-set BTB; not a large-LLC result.',
                  'SHiP-like model hashes branch PC, uses 16 two-bit counters and resolved taken reuse; not original LLC signature semantics.',
                  'Conditional confidence hints use current BHT16 counter=3 and an extra read; not true PC-specific branch probability.',
                  'Policies named lru_taken/lru_any touch only on resolution, not lookup. Retire-useful touches only correct adopted taken predictions that actually retire.']}
    (DOCS / 'btb-replacement-models.json').write_text(json.dumps(result, indent=2) + '\n')
    print('COMPLETE', len(records), 'inputs', len(contract['configs']), 'joint points', flush=True)


if __name__ == '__main__':
    main()
