#!/usr/bin/env python3
"""Export small result tables and an index to the preserved raw experiment."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil

from explore_frontend import NPC, sha
from sta_report import mapped_cells


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.root.resolve(), args.output.resolve()
    assert read(root / 'final-validation.json')['status'] == 'passed'
    assert read(root / 'validation-complete.json')['status'] == 'passed'
    out.mkdir(parents=True, exist_ok=False)
    files = ['decision.json', 'configuration-results.csv', 'case-results.csv', 'ablations.json',
             'validation-protocol.json', 'final-validation.json', 'selection-freeze.json']
    for name in ['tool-manifest.json', 'query-bypass-equivalence.json',
                 'learned-query-equivalence.json', 'host-optimization-audit.json',
                 'policy-screen-1k4way32.json', 'shortlist-final-v2.json', 'measurement-revision.json',
                 'memory-mode-audit.json', 'hex-image-audit.json', 'physical-query-equivalence.json',
                 'source-format-equivalence.json', 'preset-validation.json', 'final-lint.json',
                 'interrupt-timing-fix.json']:
        if (root / name).exists():
            files.append(name)
    for name in files:
        shutil.copy2(root / name, out / name)
    for source, destination in [('baseline/manifest.json', 'baseline-manifest.json'),
                                ('images-v1/manifest.json', 'images-manifest.json')]:
        shutil.copy2(root / source, out / destination)
    model = out / 'model'
    model.mkdir()
    for source in sorted((root / 'model-dev').glob('*.csv')):
        shutil.copy2(source, model / source.name)
    shutil.copy2(root / 'model-dev/manifest.json', model / 'manifest.json')
    # Keep only this directory's explicit machine-readable exports visible to Git.
    (out / '.gitignore').write_text('!*.json\n!*.csv\n')
    ppa = {}
    for item in read(root / 'selection-freeze.json')['rows']:
        name = item['name']
        qualified = read(root / 'ppa' / name / 'qualified.json')
        source = Path(qualified.get('original_artifacts', root / 'ppa' / name))
        cell_record = root / 'ppa' / name / 'cells.json'
        cells = read(cell_record) if cell_record.exists() else mapped_cells(
            source / 'sta/riscv32_core_reset_boundary-820MHz-buffered')
        assert abs(cells['area_um2'] - qualified['area_um2']) < 1e-6, name
        ppa[name] = {'qualified': qualified, 'cells': cells,
                     'timing': read(root / 'ppa' / name / 'timing.json'), 'raw_directory': str(source)}
    (out / 'ppa-results.json').write_text(json.dumps(ppa, indent=2) + '\n')
    logs = []
    directories = [root, *{Path(row['raw_directory']) for row in ppa.values()}]
    revision_path = root / 'measurement-revision.json'
    if revision_path.exists():
        original = Path(read(revision_path)['previous_cycle_model_root']) / 'baseline'
        shutil.copy2(original / 'manifest.json', out / 'original-baseline-manifest.json')
        directories.append(original)
    # Shared hardware/software artifacts may be linked from a measurement revision.
    directories += [path.resolve() for path in root.iterdir() if path.is_symlink() and path.is_dir()]
    # The archive command may itself be redirected into raw_root. Its stdout
    # is still being written, so it cannot be an immutable experiment input.
    active_outputs = set()
    for descriptor in [1, 2]:
        try:
            path = Path(os.readlink(f'/proc/self/fd/{descriptor}'))
            if path.is_file():
                active_outputs.add(path.resolve())
        except OSError:
            pass
    seen = set()
    for directory in directories:
        for path in directory.rglob('*'):
            path = path.resolve()
            if path in seen or path in active_outputs or not path.is_file():
                continue
            seen.add(path)
            if (path.suffix in ['.log', '.rpt'] or path.name in
                    ['manifest.json', 'source-hashes.json', 'command.json', 'constraints.sdc'] or
                    path.suffix == '.diff'):
                logs.append({'path': str(path), 'bytes': path.stat().st_size, 'sha256': sha(path)})
    (out / 'raw-log-index.json').write_text(json.dumps(logs, indent=2) + '\n')
    source_files = list((NPC / 'vsrc/riscv32').rglob('*.sv'))
    source_files += list((NPC / 'vsrc/riscv32').rglob('*.svh'))
    source_files += list((NPC / 'scripts').glob('*.py'))
    source_files += [p for p in (NPC / 'tests/interrupt').iterdir() if p.is_file()]
    source_files += [p for p in (NPC / 'tests/frontend_exploration').iterdir() if p.is_file()]
    source_files += [p for p in (NPC / 'tests/frontend_selection').rglob('*') if p.is_file()]
    source_files += list((NPC / 'tools/icache_explore').glob('*.py'))
    source_files += [p for p in (NPC / 'tools/icache_explore/sta_flow').rglob('*') if p.is_file()]
    source_files += [NPC.parent / 'abstract-machine/am/src/riscv/npc/libgcc/div.S',
                     NPC.parent / 'abstract-machine/am/src/riscv/npc/libgcc/muldi3.S']
    source_files += list((NPC / 'configs').glob('*.mk'))
    source_files += [NPC / 'Makefile', NPC / 'tools/icache_explore/model.cpp']
    source_files += [NPC / 'docs/verification/ICACHE_SELECTION_2026-09-21.md',
                     NPC / 'docs/microarchitecture/ICACHE_DESIGN_RECORD.md',
                     NPC / 'docs/microarchitecture/ICACHE_REPLACEMENT_DESIGN.md',
                     NPC / 'constr/riscv32_core_reset_boundary.sdc']
    manifest = {'created_at': datetime.now(timezone.utc).isoformat(), 'raw_root': str(root),
                'baseline_manifest_sha256': sha(root / 'baseline/manifest.json'),
                'images_manifest_sha256': sha(root / 'images-v1/manifest.json'),
                'sources': {str(p.relative_to(NPC.parent)): sha(p) for p in source_files},
                'files': {str(p.relative_to(out)): sha(p) for p in out.rglob('*') if p.is_file()},
                'note': 'Large traces, binaries, netlists and interrupted runs remain in raw_root; no remote push'}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(out)


if __name__ == '__main__':
    main()
