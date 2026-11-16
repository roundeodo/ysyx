#!/usr/bin/env python3
"""Run the selected RV32I configuration against the existing NEMU reference."""
import json
import fcntl
from pathlib import Path
import shutil
import sys

NPC = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(NPC / 'scripts'))
import verify_direction_difftest as suite
from followup_branch import defines


def balanced_defines(config):
    return defines(config) + ['YSYX_BRANCH_STATIC_POLICY=2', 'YSYX_BRANCH_EARLY_TARGET=1']


if __name__ == '__main__':
    root = NPC / 'result/wait-opt-difftest/current'
    root.parent.mkdir(parents=True, exist_ok=True)
    lock = (root.parent / '.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if root.exists():
        assert (root / '.npc-generated-workspace').is_file()
        results = root / 'difftest/results.json'
        if results.exists():
            # Keep previous small results/logs before overwriting compiler output.
            from hashlib import sha256
            label = sha256(results.read_bytes()).hexdigest()[:12]
            archive = NPC / 'docs/verification/data/wait-opt-20261002/difftest-history' / label
            archive.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(results, archive / 'results.json')
            for log in (root / 'difftest/final').glob('*.log'):
                shutil.copyfile(log, archive / (log.stem + '.txt'))
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)
    (root / '.npc-generated-workspace').write_text('wait optimization DiffTest\n')
    (root / 'configurations.json').write_text(json.dumps({'final': {}}) + '\n')
    suite.defines = balanced_defines
    sys.argv = ['verify_direction_difftest', '--root', str(root), '--configs', 'final']
    suite.main()
