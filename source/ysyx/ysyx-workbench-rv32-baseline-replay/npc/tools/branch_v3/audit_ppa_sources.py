#!/usr/bin/env python3
"""Bind each frozen result to delivered RTL; audit the earlier simple control map."""
import hashlib
import json
from pathlib import Path

from run_btb_matrix import NPC, ROOT


def main():
    docs = NPC/'docs/research/branch-v3'
    freeze = json.loads((docs/'selection-freeze.json').read_text())
    baseline_sources = json.loads((ROOT/'ppa/BT0/source-hashes.json').read_text())
    expected_sources = {path for path in baseline_sources if Path(path).suffix == '.sv'}
    rows = []
    for name, candidate in freeze['candidates'].items():
        original = candidate['ppa']
        delivered = 'H2E-delivery' if original == 'H2E-victim' else original
        point = ROOT/'ppa'/delivered
        checked = 0
        source_hashes = json.loads((point/'source-hashes.json').read_text())
        assert {path for path in source_hashes if Path(path).suffix == '.sv'} == expected_sources
        for relative, digest in source_hashes.items():
            path = NPC.parent/relative
            if path.suffix == '.sv':
                assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, path
                checked += 1
        assert checked == len(expected_sources) and checked > 0
        q = json.loads((point/'qualified.json').read_text())
        assert q['area_um2'] == candidate['area_um2'], 'Area audit changed; preserve freeze and evaluate explicitly'
        probes = []
        for mhz in candidate['mhz']:
            probe = json.loads((point/f'probe-{mhz}.json').read_text())
            assert probe['passed']
            probes.append(probe)
        row = {'candidate': name, 'frozen_ppa': original, 'delivered_ppa': delivered,
               'identical_delivered_RTL_files': checked, 'area_um2': q['area_um2'],
               'passed_frozen_frequencies': candidate['mhz']}
        if original != delivered:
            old = json.loads((ROOT/'ppa'/original/'probe-700.json').read_text())
            new = json.loads((point/'probe-700.json').read_text())
            assert old['input_sha256'] == new['input_sha256']
            assert old['groups'] == new['groups']
            row.update(reason='Earlier H2E source preceded default-off BTB options; remapped current source after freeze without retuning.',
                       identical_netlist_and_SDC_sha256=new['input_sha256'],
                       identical_700MHz_timing_groups=new['groups'])
        rows.append(row)
    (docs/'ppa-delivery-audit.json').write_text(json.dumps(rows, indent=2)+'\n')
    print('PASS delivered-source PPA binding', len(rows), 'profiles; frozen areas/clocks unchanged')


if __name__ == '__main__':
    main()
