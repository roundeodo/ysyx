#!/usr/bin/env python3
"""Compare two native train runs only after checking their shared environment."""
import argparse
import json
from pathlib import Path


def read(folder):
    return (json.loads((folder / 'manifest.json').read_text()),
            json.loads((folder / 'report.json').read_text()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('current', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    old_manifest, old = read(args.baseline)
    new_manifest, new = read(args.current)
    if any(report.get('status') != 'passed' for report in (old, new)):
        raise SystemExit('Both performance reports must be passed')
    for manifest in (old_manifest, new_manifest):
        if manifest['scale'] != 'train':
            raise SystemExit('Both reports must use train')
    for key in ('cpu_mhz', 'device_mhz', 'timer_hz', 'timing_model'):
        if old[key] != new[key]:
            raise SystemExit(f'Environment differs: {key}')
    if old_manifest['artifacts']['microbench.bin'] != new_manifest['artifacts']['microbench.bin']:
        raise SystemExit('Guest images differ; this is not an identical-image comparison')
    shared_sources = lambda manifest: {
        path: digest for path, digest in manifest['sources'].items()
        if not path.startswith('npc/vsrc/riscv32/')}
    if shared_sources(old_manifest) != shared_sources(new_manifest):
        raise SystemExit('Software, SoC model, or measurement harness sources differ')
    if old['scored']['retired_instructions'] != new['scored']['retired_instructions']:
        raise SystemExit('Scored architectural instruction counts differ; investigate before comparing')
    result = {'environment_checks': 'passed', 'cpu_mhz': old['cpu_mhz'],
              'timing_model': old['timing_model'],
              'image_sha256': old_manifest['artifacts']['microbench.bin']}
    for window in ('total', 'scored'):
        before, after = old[window], new[window]
        result[window] = {
            'baseline_cycles': before['cycles'], 'current_cycles': after['cycles'],
            'baseline_ipc': before['ipc'], 'current_ipc': after['ipc'],
            'baseline_timer_seconds': before['timer_seconds'],
            'current_timer_seconds': after['timer_seconds'],
            'same_frequency_speedup': before['cycles'] / after['cycles'],
            'cycle_reduction_percent': 100 * (1 - after['cycles'] / before['cycles'])}
    text = json.dumps(result, indent=2) + '\n'
    print(text, end='')
    if args.output:
        args.output.write_text(text)


if __name__ == '__main__':
    main()
