#!/usr/bin/env python3
"""Compare archived runs only when software, measurement and SoC timing agree."""
import argparse
import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_run(directory):
    directory = Path(directory)
    manifest_path = directory / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    report = json.loads((directory / 'report.json').read_text())
    if report.get('status') != 'passed':
        raise ValueError(f'{directory}: run did not pass')
    if report.get('manifest_sha256') != digest(manifest_path):
        raise ValueError(f'{directory}: report/manifest mismatch')
    for name in ('microbench.bin', 'microbench.elf'):
        if digest(directory / name) != manifest['artifacts'][name]:
            raise ValueError(f'{directory}: changed {name}')
    for key in ('scale', 'cpu_mhz', 'device_mhz', 'timer_hz'):
        if report.get(key) != manifest.get(key):
            raise ValueError(f'{directory}: report/config mismatch: {key}')
    for window in ('scored', 'total'):
        value = report[window]
        if value['cycles'] <= 0 or value['retired_instructions'] <= 0:
            raise ValueError(f'{directory}: invalid counters')
        if abs(value['ipc'] - value['retired_instructions'] / value['cycles']) > 1e-12:
            raise ValueError(f'{directory}: inconsistent IPC')
    return manifest, report


def environment_sources(manifest):
    # Core RTL may change. Peripheral models and measurement code must not change
    # silently in an experiment intended to measure a core hardware improvement.
    prefixes = ('ysyxSoC/', 'npc/csrc/', 'npc/include/', 'npc/vsrc/riscv/sim/')
    exact = {'npc/scripts/run_microbench_perf.py'}
    sources = {name: value for name, value in manifest['sources'].items()
               if name.startswith(prefixes) or name in exact}
    required = {'ysyxSoC/perip/amba/axi4_delayer.v',
                'ysyxSoC/perip/amba/apb_delayer.v',
                'ysyxSoC/build/ysyxSoCFull.v', *exact}
    if not required <= sources.keys():
        raise ValueError('Missing SoC timing or measurement source fingerprints')
    return sources


def compare(baseline, candidate):
    old_m, old_r = load_run(baseline)
    new_m, new_r = load_run(candidate)
    if old_m.get('environment') != 'ysyxSoC-sdram-calibrated':
        raise ValueError('Baseline is not the calibrated full SoC environment')
    for key in ('environment', 'scale', 'isa', 'cpu_mhz', 'device_mhz',
                'timer_hz', 'delay_ratio_scaled', 'delay_scale', 'layout'):
        if key not in old_m or old_m[key] != new_m.get(key):
            raise ValueError(f'Incomparable runs: {key} differs or is missing')
    for name in ('microbench.bin', 'microbench.elf'):
        if old_m['artifacts'][name] != new_m['artifacts'][name]:
            raise ValueError(f'Incomparable runs: software image differs ({name})')
    old_sources, new_sources = environment_sources(old_m), environment_sources(new_m)
    changed = sorted(name for name in old_sources.keys() | new_sources.keys()
                     if old_sources.get(name) != new_sources.get(name))
    if changed:
        raise ValueError('Incomparable runs: device model or measurement changed: ' + ', '.join(changed))
    if old_m['configuration'].get('sdram_native_read_burst') != new_m['configuration'].get('sdram_native_read_burst'):
        raise ValueError('Incomparable runs: SDRAM controller mode changed')
    if old_r['scored']['retired_instructions'] != new_r['scored']['retired_instructions']:
        raise ValueError('Scored instruction count changed; investigate before claiming a hardware gain')
    changes = {key: [old_m['configuration'].get(key), new_m['configuration'].get(key)]
               for key in old_m['configuration'].keys() | new_m['configuration'].keys()
               if key != 'simulator' and old_m['configuration'].get(key) != new_m['configuration'].get(key)}
    result = {'status': 'comparable', 'scale': old_m['scale'],
              'scope': 'same-frequency simulation; not a physical timing qualification',
              'configuration_changes': changes, 'windows': {}}
    for window in ('scored', 'total'):
        before, after = old_r[window], new_r[window]
        result['windows'][window] = {
            'baseline_cycles': before['cycles'], 'candidate_cycles': after['cycles'],
            'cycle_reduction_percent': (1 - after['cycles'] / before['cycles']) * 100,
            'speedup': before['cycles'] / after['cycles'],
            'baseline_seconds': before['cycles'] / (old_m['cpu_mhz'] * 1e6),
            'candidate_seconds': after['cycles'] / (new_m['cpu_mhz'] * 1e6),
            'baseline_ipc': before['ipc'], 'candidate_ipc': after['ipc']}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(compare(args.baseline, args.candidate), indent=2))
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(f'Comparison rejected: {error}')


if __name__ == '__main__':
    main()
