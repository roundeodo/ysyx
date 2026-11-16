#!/usr/bin/env python3
"""Vary one TAGE geometry axis at a time and check every context/state bit."""
import json
import random
import subprocess
from pathlib import Path

from models import ScaledTage
from check_tage_scl import pack_context, pack_state

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC / 'result/branch-v3/geometry-unit'
GEOMETRIES = {
    'default': {},
    'base128': {'base': 128},
    'tagged8': {'entries': 8},
    'tagged64': {'entries': 64},
    'two-banks': {'lengths': (3, 7)},
    'short-tags': {'tag_bits': 6},
    'long-history': {'lengths': (4, 13, 32)},
    'maximum': {'base': 128, 'entries': 64, 'lengths': (4, 13, 32), 'tag_bits': 10},
}


def main():
    ROOT.mkdir(exist_ok=False)
    records = []
    for name, geometry in GEOMETRIES.items():
        folder = ROOT / name
        folder.mkdir()
        reference = ScaledTage(**geometry)
        lengths = list(reference.lengths)
        parameters = {
            'BASE_ENTRIES': len(reference.base), 'TAGGED_ENTRIES': reference.entries,
            'TABLE_COUNT': len(lengths), 'TAG_BITS': reference.tag_bits,
            'HISTORY_BITS_0': lengths[0], 'HISTORY_BITS_1': lengths[1],
            'HISTORY_BITS_2': lengths[2] if len(lengths) == 3 else 16,
            'SC_ENABLE': 1, 'LOOP_ENABLE': 1,
        }
        command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
                   '--top-module', 'tage_scl_tb', '+define+BRANCH_V3_VERIFY',
                   '--Mdir', str(folder / 'obj'),
                   *[f'-G{key}={value}' for key, value in parameters.items()],
                   str(NPC / 'vsrc/riscv32/core/frontend/riscv32_tage_scl.sv'),
                   str(NPC / 'tests/branch_v3/tage_scl_tb.sv')]
        with (folder / 'build.log').open('x') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        for seed in (131, 827, 1201):
            randomizer = random.Random(seed)
            model = ScaledTage(**geometry, sc=True, loop=True)
            saved = [None] * 64
            expected, rows = [], []
            for cycle in range(4000):
                slot = cycle % 64
                train_slot = (cycle - randomizer.randrange(1, 49)) % 64
                pc = (0x100 if cycle < 300 else 0x100 + 4 * randomizer.randrange(256))
                training = saved[train_slot] if randomizer.randrange(5) else None
                taken = cycle % 5 != 4 if cycle < 300 else bool(randomizer.randrange(2))
                invalidate = cycle in (300, 301, 1900, 3111)
                query = model.lookup(pc)
                if invalidate:
                    model.invalidate()
                elif training is not None:
                    model.train(training, taken)
                expected.append((int(query['prediction']), pack_context(query), pack_state(model)))
                saved[slot] = query
                rows.append(f'{pc:x} {slot} {train_slot} {int(training is not None)} {int(taken)} {int(invalidate)}\n')
            vectors, output = folder / f'{seed}.in', folder / f'{seed}.out'
            vectors.write_text(''.join(rows))
            with (folder / f'{seed}.log').open('x') as log:
                subprocess.run([str(folder / 'obj/Vtage_scl_tb'), f'+input={vectors}', f'+output={output}'],
                               stdout=log, stderr=subprocess.STDOUT, check=True)
            actual = output.read_text().splitlines()
            assert len(actual) == len(expected)
            for cycle, (line, reference) in enumerate(zip(actual, expected)):
                fields = line.split()
                result = (int(fields[0]), int(fields[1], 16), int(fields[2], 16))
                if result != reference:
                    (folder / 'mismatch.json').write_text(json.dumps({
                        'seed': seed, 'cycle': cycle, 'actual': list(map(hex, result)),
                        'expected': list(map(hex, reference))}, indent=2) + '\n')
                    raise AssertionError((name, seed, cycle))
            records.append({'name': name, 'parameters': parameters, 'seed': seed,
                            'steps': len(expected), 'status': 'passed-full-state', 'command': command})
            (ROOT / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
            print('PASS geometry', name, seed, len(expected), flush=True)


if __name__ == '__main__':
    main()
