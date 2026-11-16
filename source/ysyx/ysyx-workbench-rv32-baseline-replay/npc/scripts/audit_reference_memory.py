#!/usr/bin/env python3
"""Verify a new reference RAM against preserved legacy counters and retirement."""
import argparse
import json
from pathlib import Path

from explore_frontend import sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--legacy-root', type=Path, required=True)
    args = parser.parse_args()
    root, old = args.root.resolve(), args.legacy_root.resolve()
    probes = json.loads((root / 'memory-tests/manifest.json').read_text())
    assert probes['status'] == 'passed'
    files = [old / 'rtl/dev-580/B0/results.json', root / 'rtl/legacy-B0/B0/results.json',
             root / 'rtl/dev-580/B0/results.json']
    before, legacy, physical = [json.loads(p.read_text()) for p in files]
    assert before.get('memory_mode', 'cycle') == legacy['memory_mode'] == 'cycle'
    assert physical['memory_mode'] == 'physical'
    assert all(len(data['results']) == 6 for data in [before, legacy, physical])
    for a, b, c in zip(before['results'], legacy['results'], physical['results']):
        assert a['case']['hashes'] == b['case']['hashes'] == c['case']['hashes']
        assert a['result'] == b['result'] and a['counters'] == b['counters'], a['case']['name']
        for key in ['retired', 'all_retired', 'digest', 'checksum']:
            assert b['result'][key] == c['result'][key], (a['case']['name'], key)
    result = {'status': 'passed', 'probe_cases': probes['cases'],
              'legacy_all_results_and_counters_equal': True,
              'physical_software_and_architectural_results_equal': True,
              'cycles_expected_to_change_with_memory_mode': True,
              'inputs': {str(p): sha(p) for p in files}}
    (root / 'memory-mode-audit.json').write_text(json.dumps(result, indent=2) + '\n')
    print('PASS legacy compatibility and physical-mode architectural equivalence', flush=True)


if __name__ == '__main__':
    main()
