#!/usr/bin/env python3
"""Map whole-core shortlist snapshots with one flow and qualify a common grid."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from explore_frontend import NPC, sha
from select_icache import CONFIGS
import sta_report as helper

ROOT = NPC.parent
FLOW = Path(os.environ.get('NPC_STA_TOOLFLOW', NPC / 'result/sta/rv32-interrupt-20260906/toolflow')).resolve()


def execute(command, cwd, env, log):
    with log.open('w') as stream:
        subprocess.run(command, cwd=cwd, env=env, stdout=stream,
                       stderr=subprocess.STDOUT, check=True)


def qualify(name, root, resume=False, *, cache_config=None, extra_make=None, source_root=None):
    out = root / name
    if (out / 'qualified.json').exists():
        return
    existing = out.exists()
    if existing and not resume:
        raise RuntimeError(f'Incomplete output; use --resume: {out}')
    out.mkdir(parents=True, exist_ok=True)
    source = out / 'source'
    filelist_root = source_root / 'npc' if source_root is not None else NPC
    files = [Path(row.replace('${NPC_HOME}', str(NPC))) for row in
             (filelist_root / 'vsrc/riscv32/filelist/filelist_sta.f').read_text().splitlines()
             if row.startswith('${NPC_HOME}')]
    if not existing:
        for path in files:
            target = source / path.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            origin = source_root / path.relative_to(ROOT) if source_root is not None else path
            shutil.copy2(origin, target)
        (out / 'source-hashes.json').write_text(json.dumps(
            {str(p.relative_to(ROOT)): sha(source / p.relative_to(ROOT)) for p in files}, indent=2) + '\n')
    else:
        for relative, digest in json.loads((out / 'source-hashes.json').read_text()).items():
            assert sha(source / relative) == digest, relative
    capacity, ways, policy, line = cache_config if cache_config is not None else CONFIGS[name]
    command = ['make', '-C', 'npc', 'git_commit=', 'NPC_CONFIG=rv32-baseline', 'sta-reset',
               'STA_FREQUENCY_MHZ=820', 'STA_SYNTH_STRATEGY=AREA 3', f'STA_TOOL_DIR={FLOW}',
               f'STA_OUTPUT_ROOT={out / "sta"}', f'NPC_ICACHE_CAPACITY_BYTES={capacity}',
               f'NPC_ICACHE_WAY_COUNT={ways}', f'NPC_ICACHE_REPLACEMENT_POLICY={policy}',
               f'NPC_ICACHE_LINE_BYTES={line}',
               'STA_RTL_DEPENDENCIES=' + ' '.join(str(source / p.relative_to(ROOT)) for p in files)]
    command.extend(extra_make or [])
    env = dict(os.environ, NPC_HOME=str(NPC), AM_HOME=str(ROOT / 'abstract-machine'),
               NEMU_HOME=str(ROOT / 'nemu'), OMP_NUM_THREADS='2')
    if existing:
        saved = json.loads((out / 'command.json').read_text())
        assert command == saved, f'Resume command changed: {name}'
    else:
        (out / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    started = time.time()
    stamp = time.strftime('%Y%m%dT%H%M%S')
    if not (out / 'cells.json').exists():
        # A killed Yosys may leave a truncated target that make would reuse.
        # Preserve that entire partial output before rebuilding the frozen sources.
        if (out / 'sta').exists():
            (out / 'sta').rename(out / ('interrupted-sta-' + stamp))
        print('SYNTH', name, flush=True)
        execute(command, ROOT, env, out / (f'synthesis-resume-{stamp}.log' if existing else 'synthesis.log'))
    qualify_mapped(name, out, env, started=started)


def qualify_mapped(name, out, env, *, started=None, initial_estimate=None):
    """Qualify an existing mapped netlist; estimates only select measured probes."""
    started = time.time() if started is None else started
    stamp = time.strftime('%Y%m%dT%H%M%S')
    mapped = out / 'sta/riscv32_core_reset_boundary-820MHz-buffered'
    cells = helper.mapped_cells(mapped)
    (out / 'cells.json').write_text(json.dumps(cells, indent=2) + '\n')
    results = json.loads((out / 'timing.json').read_text()) if (out / 'timing.json').exists() else {}

    def measure(mhz):
        if str(mhz) in results:
            return results[str(mhz)]['passed']
        target = out / f'sta/riscv32_core_reset_boundary-{mhz}MHz-buffered'
        complete = (target / 'sta.log').exists() and 'The timing engine run success.' in (target / 'sta.log').read_text()
        if not complete:
            if target.exists():
                target.rename(target.with_name(target.name + '-interrupted-' + stamp))
            target.mkdir()
            for filename in ['riscv32_core_reset_boundary.netlist.v', 'constraints.sdc']:
                shutil.copy2(mapped / filename, target / filename)
            netlist = target / 'riscv32_core_reset_boundary.netlist.v'
            sta_command = [str(FLOW / 'bin/iEDA'), '-script', str(FLOW / 'scripts/sta.tcl'),
                           str(target / 'constraints.sdc'), str(netlist), 'riscv32_core_reset_boundary', 'nangate45']
            (target / 'command.json').write_text(json.dumps(sta_command, indent=2) + '\n')
            execute(sta_command, FLOW, dict(env, NPC_STA_NETLIST_FILE=str(netlist),
                                           CLK_FREQ_MHZ=str(mhz), RUN_POWER_ANALYSIS='0'), target / 'sta.log')
        groups = helper.timing(target)
        violations = (target / 'riscv32_core_reset_boundary.rpt').read_text().count('slack (VIOLATED)')
        passed = not violations and all(g['slack_ns'] >= 0 for g in groups.values())
        results[str(mhz)] = {'groups': groups, 'violations': violations, 'passed': passed}
        (out / 'timing.json').write_text(json.dumps(results, indent=2) + '\n')
        print('STA', name, mhz, 'PASS' if passed else 'FAIL', flush=True)
        return passed

    # Fixed-period synchronous STA setup limits are monotone with clock period.
    # Keep the same 20 MHz grid; verify both the pass point and its upper neighbour.
    # Unexpected hold failures/non-monotone cached results trigger an exhaustive scan.
    # Reuse the completed mapping-point report only to choose the first probe.
    # Every accepted grid frequency and its failing upper neighbour still run STA.
    if initial_estimate is None:
        initial_estimate = helper.timing(mapped)['data_max'].get('fmax_mhz')
    mhz = helper.qualify_grid(measure, results, initial_estimate=initial_estimate)
    if mhz is None:
        raise RuntimeError(f'No qualifying frequency: {name}')
    assert measure(mhz)
    if mhz < 800:
        assert not measure(mhz + 20)
    (out / 'qualified.json').write_text(json.dumps({
        'mhz': mhz, 'grid_mhz': 20, 'search_upper_mhz': 800, 'all_groups_passed': True,
        'area_um2': cells['area_um2'], 'wall_seconds': time.time() - started,
        'search': 'estimate-seeded cached/binary grid search; pass point and upper neighbour measured',
        'source': f'timing.json:{mhz}'}, indent=2) + '\n')
    print('PASS', name, mhz, cells['area_um2'], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--configs', nargs='+', choices=CONFIGS, required=True)
    parser.add_argument('--jobs', type=int, choices=[1, 2], default=1)
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for result in pool.map(lambda name: qualify(name, args.output.resolve(), args.resume), args.configs):
            pass


if __name__ == '__main__':
    main()
