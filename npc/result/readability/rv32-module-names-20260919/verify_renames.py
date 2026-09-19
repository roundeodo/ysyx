"""Verify exact, bijective module/instance renames across all original RTL files."""
import hashlib
import json
from pathlib import Path
import re
import tarfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
aliases = json.loads((HERE / 'identifier-map.json').read_text())
paths = json.loads((HERE / 'path-map.json').read_text())
before = json.loads((HERE / 'before-hashes.json').read_text())
assert len(set(aliases.values())) == len(aliases)
pattern = re.compile(r'\b(?:' + '|'.join(sorted(map(re.escape, aliases), key=len, reverse=True)) + r')\b')
current_paths = {str(p.relative_to(ROOT)) for p in (ROOT / 'npc/vsrc/riscv32').rglob('*') if p.is_file()}
assert {paths.get(path, path) for path in before} == current_paths
report = {}
with tarfile.open(HERE / 'before-source.tar.gz') as archive:
    for path, digest in before.items():
        original = archive.extractfile(path).read()
        assert hashlib.sha256(original).hexdigest() == digest, path
        expected = pattern.sub(lambda match: aliases[match[0]], original.decode()).encode()
        target = paths.get(path, path)
        actual = (ROOT / target).read_bytes()
        assert actual == expected, target
        report[target] = {'status': 'passed', 'sha256': hashlib.sha256(actual).hexdigest()}
for path in paths:
    assert not (ROOT / path).exists(), path
for name in ('filelist.f', 'filelist_sta.f'):
    for line in (ROOT / 'npc/vsrc/riscv32/filelist' / name).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith(('//', '+', '-')):
            continue
        assert Path(line.replace('${NPC_HOME}', str(ROOT / 'npc'))).is_file(), line
(HERE / 'rename-check.json').write_text(json.dumps(report, indent=2) + '\n')
with tarfile.open(HERE / 'after-source.tar.gz', 'w:gz') as archive:
    for path in sorted(current_paths):
        archive.add(ROOT / path, arcname=path)
print(f'PASS: {len(report)} files; {len(paths)} one-to-one path changes; all other bytes unchanged.')
