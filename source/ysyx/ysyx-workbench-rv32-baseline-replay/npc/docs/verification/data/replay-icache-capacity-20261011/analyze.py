#!/usr/bin/env python3
"""Reproduce the replay comparisons from the adjacent compact evidence."""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load(name):
    folder = ROOT / name
    manifest = json.loads((folder / 'manifest.json').read_text())
    report = json.loads((folder / 'report.json').read_text())
    log = (folder / 'simulation.log').read_text()
    require(report['status'] == 'passed', f'{name} did not pass')
    require(not manifest['dcache']['enabled'], f'{name} enables D-cache')

    def numbers(pattern):
        match = re.search(pattern, log, re.MULTILINE)
        require(match is not None, f'{name}: missing {pattern}')
        return [int(value) for value in match.groups()]

    active, = numbers(r'^active core cycles\s*:\s*(\d+)')
    keys = ['issued instructions', 'control recovery stalls', 'LSU structural stalls',
            'unresolved RAW stalls', 'serializing stalls', 'frontend supply stalls',
            'other empty issue slots']
    slots = {key: numbers(r'^\s*' + re.escape(key) + r'\s*:\s*(\d+)')[0]
             for key in keys}
    require(sum(slots.values()) == active, f'{name}: issue attribution does not sum')
    lookups, hits, misses = numbers(
        r'^lookups / cacheable hits / cacheable misses\s*:\s*(\d+) / (\d+) / (\d+)')
    corrections = numbers(
        r'^actual EX corrections by branch / JAL / JALR\s*:\s*(\d+) / (\d+) / (\d+)')
    discarded, = numbers(r'^IFU discarded wrong-path responses\s*:\s*(\d+)')
    return manifest, report, {
        'scope': 'whole-program PMU, not native Total or Scored windows',
        'active_cycles': active, 'exclusive_issue_cycles': slots,
        'exclusive_issue_percent': {k: 100 * v / active for k, v in slots.items()},
        'icache': {'lookups': lookups, 'hits': hits, 'misses': misses},
        'ex_corrections': dict(zip(['branch', 'jal', 'jalr'], corrections)),
        'wrong_path_responses': discarded,
    }


def compare(before_name, after_name, same_sources):
    old_m, old_r, old_pmu = load(before_name)
    new_m, new_r, new_pmu = load(after_name)
    require(old_m['scale'] == new_m['scale'], 'Workload scales differ')
    for key in ['cpu_mhz', 'device_mhz', 'timer_hz', 'timing_model']:
        require(old_r[key] == new_r[key], f'{key} differs')
    require(old_m['artifacts']['microbench.bin'] == new_m['artifacts']['microbench.bin'],
            'Software images differ')
    paths = old_m['sources'].keys() | new_m['sources'].keys()
    changed = sorted(p for p in paths
                     if old_m['sources'].get(p) != new_m['sources'].get(p))
    if same_sources:
        require(not changed, 'Capacity comparison changes sources')
        require(all(r['observer_on_off_verified'] for r in [old_r, new_r]),
                'Capacity comparison lacks observer neutrality verification')
        require(not old_m['predictor']['enabled'] and not new_m['predictor']['enabled'],
                'Capacity comparison enables prediction')
        require(all(m['branch_experiments']['EARLY_TARGET'] == 0 and
                    m['branch_experiments']['STATIC_POLICY'] == 0 for m in [old_m, new_m]),
                'Capacity comparison enables early targets or a static policy')
        for key in ['ways', 'line_bytes', 'policy']:
            require(old_m['icache'][key] == new_m['icache'][key], f'I-cache {key} differs')
        require(old_m['icache']['bytes'] == 256 and new_m['icache']['bytes'] == 1024,
                'Unexpected cache capacities')
    else:
        # The old strict comparator correctly rejects these two wrapper changes.
        # Their archived diff contains defaults/help/argument validation only;
        # measurement, image build, and runtime model sources are unchanged.
        wrappers = {'npc/Makefile', 'npc/scripts/run_microbench_perf.py'}
        require({p for p in changed if not p.startswith('npc/vsrc/riscv32/')} == wrappers,
                'Unexpected software/model/harness changes in train comparison')
        require((ROOT / 'reviewed-wrapper-diff.txt').is_file(), 'Wrapper review missing')
        require(old_m['icache'] == new_m['icache'], 'Train cache configurations differ')

    result = {'before': before_name, 'after': after_name,
              'scale': old_m['scale'], 'cpu_mhz': old_r['cpu_mhz'],
              'timing_model': old_r['timing_model'],
              'image_sha256': old_m['artifacts']['microbench.bin'],
              'changed_sources': changed,
              'comparison_scope': ('identical current source, capacity only' if same_sources else
                                   'historical replay versus hybrid integration; wrappers reviewed'),
              'whole_program_pmu': {'before': old_pmu, 'after': new_pmu}}
    for window in ['total', 'scored']:
        a, b = old_r[window], new_r[window]
        if window == 'scored' and not same_sources:
            require(a['retired_instructions'] == b['retired_instructions'],
                    'Scored instruction counts differ')
        result[window] = {
            'before': a, 'after': b,
            'cycle_reduction_percent': 100 * (1 - b['cycles'] / a['cycles']),
            'same_frequency_speedup': a['cycles'] / b['cycles'],
            'ipc_increase_percent': 100 * (b['ipc'] / a['ipc'] - 1),
            'retired_instruction_delta': b['retired_instructions'] - a['retired_instructions'],
        }
    result['icache_miss_reduction_percent'] = 100 * (
        1 - new_pmu['icache']['misses'] / old_pmu['icache']['misses'])
    result['ex_correction_reduction_percent'] = 100 * (
        1 - sum(new_pmu['ex_corrections'].values()) / sum(old_pmu['ex_corrections'].values()))
    return result


def main():
    result = {
        'train_predictor_comparison': compare('no-predictor-train', 'hybrid-train', False),
        'test_capacity_comparison': compare('icache256-test', 'icache1k-test', True),
        'not_measured': ['1 KiB no-predictor train', 'new synthesis/STA', 'NEMU DiffTest'],
        'cautions': [
            'Do not extrapolate test speedup to train.',
            'Exclusive issue categories are prioritized attribution, not independent costs.',
            'IFU wait counters and miss penalties overlap other stalls; do not add them.',
            '700 MHz is a simulation parameter here, not a new timing qualification.',
            'Capacity test Scored retires 430311 versus 430307 instructions; '
            'native sample boundaries are timer read effects, not fixed retirement indices. '
            'The four-instruction difference has not been traced instruction by instruction.',
        ],
    }
    (ROOT / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    index = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name != 'files.json'}
    (ROOT / 'files.json').write_text(json.dumps(index, indent=2) + '\n')
    for name in ['train_predictor_comparison', 'test_capacity_comparison']:
        item = result[name]
        print(name, 'Total cycle reduction:', item['total']['cycle_reduction_percent'],
              'Scored cycle reduction:', item['scored']['cycle_reduction_percent'])


if __name__ == '__main__':
    main()
