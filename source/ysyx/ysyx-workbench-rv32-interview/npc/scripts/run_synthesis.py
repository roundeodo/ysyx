#!/usr/bin/env python3
"""Run synthesis in bounded scratch space; retain configuration and STA reports."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from result_workspace import ResultWorkspace

NPC = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['sta', 'sta-core', 'sta-qualified', 'sta-reset'], default='sta')
    parser.add_argument('--output', type=Path, default=NPC/'result/synthesis/current')
    parser.add_argument('--keep-artifacts', action='store_true')
    parser.add_argument('settings', nargs='*', help='Make assignments, e.g. STA_FREQUENCY_MHZ=700')
    args = parser.parse_args()
    for setting in args.settings:
        key, sep, _ = setting.partition('=')
        if not sep or not key.replace('_', '').isalnum() or key in {'STA_OUTPUT_ROOT', 'STA_RESET_OUTPUT_DIR'}:
            parser.error('Expected a Make variable assignment; output directories are managed automatically')
    with ResultWorkspace(NPC, args.output, 'synthesis', keep=args.keep_artifacts) as run:
        command = ['make', '-C', str(NPC), args.target, 'git_commit=', *args.settings,
                   f'STA_OUTPUT_ROOT={run.root / "sta"}']
        git = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=NPC, text=True, capture_output=True)
        sources = [NPC/'Makefile', *list((NPC/'vsrc').rglob('*.sv')),
                   *list((NPC/'vsrc').rglob('*.svh')), *list((NPC/'constr').rglob('*.sdc'))]
        config = {'command': command, 'commit': git.stdout.strip(),
                  'source_hashes': {str(p.relative_to(NPC)): hashlib.sha256(p.read_bytes()).hexdigest()
                                    for p in sources if p.is_file()}}
        (run.root/'configuration.json').write_text(json.dumps(config, indent=2)+'\n')
        print('Running: '+' '.join(command), flush=True)
        with (run.root/'synthesis.log').open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        # Keep textual timing reports and known scalar statistics, never netlist JSON.
        for p in (run.root/'sta').rglob('*'):
            if p.is_symlink() or not p.is_file() or p.stat().st_size > 2*1024*1024:
                continue
            if p.suffix == '.rpt' or p.name in {'timing.json', 'qualified.json', 'qualification.json', 'synth_stat.txt', 'stat.txt'}:
                dest = run.root/'analysis'/p.relative_to(run.root/'sta')
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(p, dest)
        with (run.root/'synthesis.log').open('rb') as log:
            log.seek(max(0, (run.root/'synthesis.log').stat().st_size-65536))
            tail = log.read().decode(errors='replace')
        analysis = run.root/'analysis'
        analysis.mkdir(exist_ok=True)
        (analysis/'tool-tail.txt').write_text(tail)
        (run.root/'summary.json').write_text(json.dumps({
            'tool_exit_code': result.returncode,
            'timing_status': 'Inspect retained timing reports; tool success alone does not qualify frequency',
            'reports': [str(p.relative_to(run.root)) for p in analysis.rglob('*') if p.is_file()]}, indent=2)+'\n')
        result.check_returncode()


if __name__ == '__main__':
    main()
