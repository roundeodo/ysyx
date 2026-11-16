#!/usr/bin/env python3
"""Delayed-training directed phases and observed logical-state coverage for SC/loop."""
import argparse
import collections
import json
import random
import subprocess
from pathlib import Path
from models import ScaledTage
from check_tage_scl import pack_context, pack_state

NPC = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--name', default='directed-state')
    args = parser.parse_args()
    out = NPC/'result/branch-v3'/args.name
    out.mkdir(exist_ok=False)
    command = ['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',
               '--top-module','tage_scl_tb','-GSC_ENABLE=1','-GLOOP_ENABLE=1',
               '+define+BRANCH_V3_VERIFY','--Mdir',str(out/'obj'),
               str(NPC/'vsrc/riscv32/core/frontend/riscv32_tage_scl.sv'),
               str(NPC/'tests/branch_v3/tage_scl_tb.sv')]
    with (out/'build.log').open('x') as log:
        subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
    phases = [('stable-trip',0x100,t) for t in ([True]*3+[False])*12]
    phases += [('phase-change',0x100,t) for t in ([True]*5+[False])*12]
    phases += [('overflow',0x100,True)]*520
    phases += [('relearn',0x100,t) for t in ([True]*2+[False])*12]
    phases += [('all-not-taken',0x100,False)]*520
    rng = random.Random(4919)
    phases += [('alias-and-late',0x100+4*rng.randrange(256),bool(rng.randrange(2))) for _ in range(8000)]
    model, pending = ScaledTage(sc=True,loop=True), None
    saved, rows, expected = [None]*64, [], []
    coverage = collections.Counter()
    state_values = collections.defaultdict(set)
    for cycle,(phase,pc,taken) in enumerate(phases):
        slot, train_slot = cycle%64,(cycle-1)%64
        train = pending is not None
        invalidate = cycle in (1001,2001,2002,4001)
        query = model.lookup(pc)
        if query['provider'] >= 0:
            coverage['provider_hit'] += 1
            coverage['weak_provider'] += query['weak']
            coverage['alternate_disagreement'] += query['raw'] != query['alt']
        coverage['sc_override'] += query['prediction'] != query['tage'] and query.get('loop_prediction') is None
        if invalidate:
            model.invalidate()
            coverage['invalidate_with_train_and_query'] += train
        elif train:
            model.train(saved[train_slot],pending)
        rows.append(f'{pc:x} {slot} {train_slot} {int(train)} {int(bool(pending))} {int(invalidate)}\n')
        expected.append((int(query['prediction']),pack_context(query),pack_state(model)))
        saved[slot],pending = query,taken
        state_values['base_counter'].update(model.base)
        state_values['threshold'].add(model.threshold)
        state_values['alternate_selector'].add(model.alt_select)
        state_values['sc_weights'].update(value for table in model.weights for value in table)
        for table in model.tables:
            for entry in table:
                if entry:
                    state_values['tagged_counter'].add(entry['ctr'])
                    state_values['useful'].add(entry['u'])
        for entry in model.loops:
            if entry:
                state_values['loop_current'].add(entry['current'])
                state_values['loop_trip'].add(entry['trip'])
                state_values['loop_confidence'].add(entry['confidence'])
        coverage[phase] += 1
    vectors,actual = out/'vectors.txt',out/'actual.txt'
    vectors.write_text(''.join(rows))
    run = [str(out/'obj/Vtage_scl_tb'),f'+input={vectors}',f'+output={actual}']
    with (out/'run.log').open('x') as log:
        subprocess.run(run,stdout=log,stderr=subprocess.STDOUT,check=True)
    lines = actual.read_text().splitlines()
    assert len(lines) == len(expected)
    for index,(line,reference) in enumerate(zip(lines,expected)):
        row = line.split()
        observed = int(row[0]),int(row[1],16),int(row[2],16)
        assert observed == reference,(index,phases[index][0],observed,reference)
    assert state_values['base_counter'] == set(range(4))
    assert {-4,3} <= state_values['tagged_counter']
    assert {0,255} <= state_values['loop_current']
    assert {3,4,6} <= state_values['loop_trip']
    assert state_values['loop_confidence'] == set(range(4))
    (out/'results.json').write_text(json.dumps({'events':len(lines),'command':command,'run_command':run,
        'coverage':dict(coverage),'observed_state_values':{key:sorted(value) for key,value in state_values.items()},
        'scope':'Full query/context/logical-state comparison; coverage is observed values, not universal proof'},indent=2)+'\n')
    print('PASS directed SC/loop state',len(lines),dict(coverage))


if __name__ == '__main__':
    main()
