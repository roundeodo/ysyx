#!/usr/bin/env python3
"""Check this readability change against its frozen commit (not a formal proof).

Ignore comments/whitespace, apply the documented identifier renames, and permit
only two independent continuous assignments to move within IFU g_return_hold.
Any other token change fails. Run from any working directory.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
BASELINE = json.loads((HERE / 'baseline.json').read_text())
RENAMES = json.loads((HERE / 'renames.json').read_text())
LEXER = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*|\s+|.', re.S)
MOVED_ASSIGNMENTS = (
    'assign selected_return_target_present = return_hold_present_q ? '
    'return_hold_target_present_q : early_return_present_i;',
    'assign selected_return_pc = return_hold_present_q ? return_hold_pc_q : early_return_pc_i;',
)


def tokens(source, renames):
    return [renames.get(word, word) for word in LEXER.findall(source)
            if not word.isspace() and not word.startswith(('//', '/*'))]


def remove_once(sequence, part):
    positions = [i for i in range(len(sequence) - len(part) + 1)
                 if sequence[i:i + len(part)] == part]
    assert len(positions) == 1, ('assignment count', positions)
    start = positions[0]
    return sequence[:start] + sequence[start + len(part):]


def compare(path, mapping):
    old = subprocess.check_output(
        ['git', 'show', f"{BASELINE['base_commit']}:{path}"], cwd=REPO)
    new = (REPO / path).read_bytes()
    if path in BASELINE['files']:
        assert hashlib.sha256(old).hexdigest() == BASELINE['files'][path]['sha256']
    before, after = tokens(old.decode(), mapping), tokens(new.decode(), {})
    if Path(path).name == 'riscv32_ifu.sv':
        for assignment in MOVED_ASSIGNMENTS:
            part = tokens(assignment, {})
            before, after = remove_once(before, part), remove_once(after, part)
    assert before == after, f'Unexpected token change: {path}'
    return {'path': path, 'changed': old != new,
            'sha256': hashlib.sha256(new).hexdigest(), 'token_check': 'passed'}


if __name__ == '__main__':
    results = [compare(path, RENAMES.get(Path(path).name, {}))
               for path in BASELINE['files']]
    test = compare('npc/tests/branch_v3/tage_scl_tb.sv', {'step': 'saturating_step'})
    report = {'base_commit': BASELINE['base_commit'], 'files': results, 'test': test,
              'relocated_continuous_assignments': list(MOVED_ASSIGNMENTS)}
    print(json.dumps(report, indent=2))
