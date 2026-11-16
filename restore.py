#!/usr/bin/env python3
"""Restore current files and original Git/index state; Python 3.6+."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

def git(path, *args):
    subprocess.check_call(['git', '-C', str(path)] + list(args),
                          env=dict(os.environ, GIT_TERMINAL_PROMPT='0'))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--source-only', action='store_true', help='Restore files without fetching Git history')
    parser.add_argument('--only', help='Restore one relative repository path, e.g. ysyx/ysyx-workbench-rv32-baseline-replay')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / 'PROJECT-MANIFEST.json').read_text(encoding='utf-8'))
    repos = manifest['repos']
    if args.only:
        repos = [r for r in repos if r['relative_path'] == args.only]
        if not repos:
            raise SystemExit('Unknown repository: ' + args.only)
    dest = args.destination.expanduser().resolve()
    if dest.exists() and any(dest.iterdir()):
        raise SystemExit('Destination must be empty: ' + str(dest))
    dest.mkdir(parents=True, exist_ok=True)
    report = []
    for repo in repos:
        target = dest / repo['relative_path']
        target.mkdir(parents=True, exist_ok=True)
        has_history = bool(repo.get('history_ref')) and not args.source_only
        if has_history:
            git(target, 'init', '-q')
            git(target, 'symbolic-ref', 'HEAD', 'refs/heads/__migration_initial__')
            git(target, '-c', 'gc.auto=0', 'fetch', '-q', '--no-tags', manifest['remote'],
                repo['history_ref'],
                '+refs/heads/' + repo['branch_history_prefix'] + '*:refs/heads/*')
            git(target, 'checkout', '-q', '--detach', repo['head'])
            if repo['branch']:
                git(target, 'checkout', '-q', repo['branch'])
            git(target, 'remote', 'add', 'origin', repo['origin'])
            for filename, options in [('staged.patch', ['--index']), ('unstaged.patch', [])]:
                patch = root / repo['metadata'] / filename
                if patch.stat().st_size:
                    git(target, 'apply', *options, str(patch))
        report.append({'repository': repo['relative_path'], 'original_head': repo['head'],
                       'history_restored': has_history,
                       'note': '' if has_history else 'Source snapshot; origin/HEAD recorded in PROJECT-MANIFEST.json'})
    source = root / 'source'
    allowed = tuple(r['relative_path'] + '/' for r in repos)
    for path in sorted(source.rglob('*')):
        relative = path.relative_to(source)
        if args.only and not str(relative).startswith(allowed):
            continue
        target = dest / relative
        if path.is_symlink():
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() or target.is_symlink():
                target.unlink()
            target.symlink_to(os.readlink(path))
        elif path.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(path), str(target))
    (dest / 'RESTORE-REPORT.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Restored to ' + str(dest))

if __name__ == '__main__':
    main()
