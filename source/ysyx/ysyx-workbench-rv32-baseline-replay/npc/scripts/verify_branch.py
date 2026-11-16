#!/usr/bin/env python3
"""Run frontend recovery and architectural safety with explicit branch knobs."""
import argparse
import json
import time
from compact_target_artifacts import prune_objects
from pathlib import Path

from explore_branch import defines
from explore_frontend import NPC, run, sha


def check_sources(folder, selected=None):
    # Each suite freezes the files it actually compiled. Reusing a status marker
    # after a source edit must fail, even when the parameter names are unchanged.
    for relative in ['frontend/fetch/manifest.json', 'recovery/core/manifest.json',
                     'recovery/cache/manifest.json', 'exception/manifest.json']:
        if selected is not None and relative != selected:
            continue
        record = json.loads((folder / relative).read_text())
        sources = record.get('sources', record.get('source_sha256'))
        assert sources
        for name, expected in sources.items():
            path = Path(name)
            if not path.is_absolute():
                path = NPC / path
            assert sha(path) == expected, f'Safety source changed: {path}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--configs', nargs='+', required=True)
    parser.add_argument('--direction-study', action='store_true', help='Use the followup cache and direction configuration schema')
    parser.add_argument('--target-study', action='store_true')
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    if args.target_study and args.direction_study:
        parser.error('Choose one study schema')
    if args.target_study:
        from explore_target_storage import defines as selected_defines
    elif args.direction_study:
        from followup_branch import defines as selected_defines
    else:
        selected_defines = defines
    root = args.root.resolve()
    configs = json.loads((root / 'configurations.json').read_text())
    for name in args.configs:
        folder = root / 'verification' / name
        manifest = folder / 'manifest.json'
        if manifest.exists():
            saved = json.loads(manifest.read_text())
            assert saved['config'] == configs[name] and saved['status'] == 'passed'
            check_sources(folder)
            continue
        assert not folder.exists() or args.resume, f'Use --resume for incomplete suite: {folder}'
        folder.mkdir(parents=True, exist_ok=True)
        overrides = [setting.replace('YSYX_', 'NPC_', 1) for setting in selected_defines(configs[name])]
        overrides += [f'FRONTEND_TEST_OUTPUT={folder / "frontend"}',
                      f'CACHE_RECOVERY_OUTPUT={folder / "recovery"}',
                      f'EXCEPTION_TEST_OUTPUT={folder / "exception"}']
        records = json.loads((folder / 'progress.json').read_text()) if (folder / 'progress.json').exists() else []
        suite_manifest = dict(zip(['test-fetch', 'test-fence-i', 'test-dcache-recovery', 'test-precise-exception'],
                                  ['frontend/fetch/manifest.json', 'recovery/core/manifest.json', 'recovery/cache/manifest.json', 'exception/manifest.json']))
        for goal in ['test-fetch', 'test-fence-i', 'test-dcache-recovery', 'test-precise-exception']:
            command = ['make', 'git_commit=', 'NPC_CONFIG=rv32-baseline', *overrides, goal]
            previous = [r for r in records if r['command'][-1] == goal]
            if previous:
                assert previous == [{'command': command, 'status': 'passed'}]
                check_sources(folder, suite_manifest[goal])
                continue
            log = folder / (goal + '.log')
            if log.exists():
                log.rename(log.with_name(log.name + '.interrupted-' + time.strftime('%H%M%S')))
            run(command, log)
            records.append({'command': command, 'status': 'passed'})
            (folder / 'progress.json').write_text(json.dumps(records, indent=2) + '\n')
            if args.target_study:
                prune_objects(folder)
            print('PASS branch safety', name, goal, flush=True)
        manifest.write_text(json.dumps({'status': 'passed', 'config': configs[name],
                                       'tests': records}, indent=2) + '\n')
        check_sources(folder)


if __name__ == '__main__':
    main()
