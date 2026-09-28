#!/usr/bin/env python3
"""Measure an equivalent buffer-tree control for high-fanout BHT training data."""
import argparse
import copy
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from explore_frontend import sha
from select_icache_ppa import FLOW, qualify_mapped

TOP = 'riscv32_core_reset_boundary'
PARENTS = {'G256F': 'G256', 'G512F': 'G512', 'B512F': 'B512'}
# Fixed before held testing. Small tables retain their exact original mapping.
TRIGGER_LOADS = 64
TREE_FANOUT = 16
BUFFER_CELL = 'BUF_X4'
TRAINING_NET = re.compile(r'^u_core\.u_branch_predictor\.u_bht\.g_counter_table\.training_counter_[01]_$')


def inspect(module):
    roots = {bits['bits'][0]: name for name, bits in module['netnames'].items()
             if TRAINING_NET.fullmatch(name)}
    loads = {bit: [] for bit in roots}
    for name, cell in module['cells'].items():
        for port, bits in cell['connections'].items():
            if cell['port_directions'][port] == 'input':
                for index, bit in enumerate(bits):
                    if bit in loads:
                        loads[bit].append((name, port, index))
    return roots, loads


def repair(module, roots, loads):
    original_cells = copy.deepcopy(module['cells'])
    cells = module['cells']
    next_bit = max(bit for cell in cells.values() for bits in cell['connections'].values()
                   for bit in bits if isinstance(bit, int)) + 1
    aliases = {}
    added = []

    def distribute(root_bit, driver, sinks):
        nonlocal next_bit
        if len(sinks) <= TREE_FANOUT:
            for name, port, index in sinks:
                cells[name]['connections'][port][index] = driver
            return
        group_count = min(TREE_FANOUT, math.ceil(len(sinks) / TREE_FANOUT))
        group_size = math.ceil(len(sinks) / group_count)
        for start in range(0, len(sinks), group_size):
            name = f'bht_training_buffer_{len(added)}'
            assert name not in cells
            bit = next_bit
            next_bit += 1
            added.append(name)
            aliases[bit] = root_bit
            cells[name] = {'hide_name': 0, 'type': BUFFER_CELL, 'parameters': {}, 'attributes': {},
                           'port_directions': {'A': 'input', 'Z': 'output'},
                           'connections': {'A': [driver], 'Z': [bit]}}
            module['netnames'][name + '_out'] = {'hide_name': 0, 'bits': [bit], 'attributes': {}}
            distribute(root_bit, bit, sinks[start:start + group_size])

    for bit, sinks in loads.items():
        if len(sinks) > TRIGGER_LOADS:
            # This control fixes the two broadcast data inputs, not clock/reset nets.
            assert all(cells[n]['type'].startswith('DFF') and p == 'D' for n, p, _ in sinks)
            distribute(bit, bit, sinks)
    assert added, 'No high-fanout training bus; use --check-noop instead'
    canonical = {bit: bit for bit in roots}
    for name in added:
        cell = cells[name]
        source = cell['connections']['A'][0]
        target = cell['connections']['Z'][0]
        assert source in canonical and cell['type'] == BUFFER_CELL
        canonical[target] = canonical[source]
        assert aliases[target] == canonical[target]
    # Collapse only the inserted, acyclic, non-inverting buffers. Every original
    # cell, parameter, direction and connection must match exactly afterward.
    for name, original in original_cells.items():
        restored = copy.deepcopy(cells[name])
        restored['connections'] = {p: [aliases.get(b, b) for b in bits]
                                   for p, bits in restored['connections'].items()}
        assert restored == original, name
    assert set(cells) == set(original_cells) | set(added)
    fanouts = {bit: 0 for bit in canonical}
    for cell in cells.values():
        for port, bits in cell['connections'].items():
            if cell['port_directions'][port] == 'input':
                for bit in bits:
                    if bit in fanouts:
                        fanouts[bit] += 1
    assert max(fanouts.values()) <= TREE_FANOUT
    return {'buffer_count': len(added), 'maximum_fanout': max(fanouts.values()),
            'structural_equivalence': 'passed', 'added_registers': 0,
            'original_loads': {roots[b]: len(v) for b, v in loads.items()}}


def quote(path):
    return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"'


def run(root, name):
    parent = root / 'ppa' / PARENTS[name]
    assert (parent / 'qualified.json').exists(), 'Complete the unchanged parent first'
    out = root / 'ppa' / name
    if (out / 'qualified.json').exists():
        return
    out.mkdir(parents=True, exist_ok=True)
    mapped = out / f'sta/{TOP}-820MHz-buffered'
    mapped.mkdir(parents=True, exist_ok=True)
    source = parent / f'sta/{TOP}-820MHz-buffered'
    started = time.time()
    provenance = out / 'buffer-repair.json'
    if not provenance.exists():
        source_json = source / 'buffered.json'
        design = json.loads(source_json.read_text())
        module = design['modules'][TOP]
        roots, loads = inspect(module)
        assert len(roots) == 2
        ports = copy.deepcopy(module['ports'])
        result = repair(module, roots, loads)
        assert module['ports'] == ports
        repaired = mapped / 'buffered.json'
        repaired.write_text(json.dumps(design))
        library = FLOW / 'pdk/nangate45/lib/Nangate45_typ.lib'
        script = mapped / 'write.ys'
        script.write_text(f'read_json {quote(repaired)}\nhierarchy -top {TOP}\nselect {TOP}\n'
                          f'tee -o {quote(mapped / "synth_check.txt")} check -mapped\n'
                          f'tee -o {quote(mapped / "synth_stat.txt")} stat -liberty {quote(library)}\n'
                          f'write_verilog -noattr -noexpr -nohex -nodec {quote(mapped / (TOP+".netlist.v"))}\n')
        with (mapped / 'write.log').open('w') as log:
            subprocess.run(['yosys', '-Q', '-T', '-s', str(script)], stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=900)
        assert 'Found and reported 0 problems.' in (mapped / 'synth_check.txt').read_text()
        shutil.copy2(source / 'constraints.sdc', mapped / 'constraints.sdc')
        shutil.copy2(parent / 'source-hashes.json', out / 'source-hashes.json')
        shutil.copytree(parent / 'source', out / 'source', dirs_exist_ok=True)
        result.update({'parent': PARENTS[name], 'threshold_loads': TRIGGER_LOADS,
                       'tree_fanout': TREE_FANOUT, 'buffer_cell': BUFFER_CELL,
                       'parent_netlist_sha256': sha(source / (TOP+'.netlist.v')),
                       'parent_json_sha256': sha(source_json), 'repaired_json_sha256': sha(repaired),
                       'netlist_sha256': sha(mapped / (TOP+'.netlist.v')),
                       'constraints_sha256': sha(mapped / 'constraints.sdc'),
                       'script_sha256': sha(Path(__file__)),
                       'mapping_note': 'Reuse parent mapping; insert only explicit data buffers. Original result is retained.'})
        provenance.write_text(json.dumps(result, indent=2) + '\n')
        del design, module
    else:
        saved = json.loads(provenance.read_text())
        assert saved['parent_netlist_sha256'] == sha(source / (TOP+'.netlist.v'))
        assert saved['netlist_sha256'] == sha(mapped / (TOP+'.netlist.v'))
        assert saved['script_sha256'] == sha(Path(__file__))
    qualify_mapped(name, out, dict(os.environ, OMP_NUM_THREADS='2'),
                   started=started, initial_estimate=720)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--config', choices=PARENTS)
    p.add_argument('--check-noop', nargs='+')
    a = p.parse_args(); root = a.root.resolve()
    if a.check_noop:
        results = {}
        for name in a.check_noop:
            source = root / 'ppa' / name / f'sta/{TOP}-820MHz-buffered'
            module = json.loads((source / 'buffered.json').read_text())['modules'][TOP]
            roots, loads = inspect(module)
            assert all(len(v) <= TRIGGER_LOADS for v in loads.values())
            results[name] = {'original_loads': {roots[b]: len(v) for b, v in loads.items()},
                             'unchanged_netlist_sha256': sha(source / (TOP+'.netlist.v')),
                             'inserted_buffers': 0}
        (root / 'training-buffer-noop.json').write_text(json.dumps(results, indent=2) + '\n')
        print('PASS unchanged small-table mappings', flush=True)
    else:
        if a.config is None: p.error('--config or --check-noop is required')
        run(root, a.config)


if __name__ == '__main__':
    main()
