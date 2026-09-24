#!/usr/bin/env python3
"""Retain target-study evidence while releasing reproducible build intermediates."""
import hashlib
import json
from pathlib import Path
import shutil
import tarfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prune_objects(folder):
    removed = []
    for path in folder.rglob('*'):
        if path.is_file() and path.suffix in ('.gch', '.o', '.a'):
            removed.append({'path': str(path.relative_to(folder)), 'bytes': path.stat().st_size})
            path.unlink()
    return removed


def archive_sta(folder):
    """Only after qualification: archive every raw STA artifact, verify, then compact."""
    assert (folder / 'qualified.json').exists()
    source = folder / 'sta'
    if not source.exists():
        return
    hashes = {str(p.relative_to(folder)): sha(p) for p in source.rglob('*') if p.is_file()}
    archive = folder / 'sta.tar.gz'
    with tarfile.open(archive, 'w:gz', compresslevel=3) as out:
        out.add(source, arcname='sta')
    with tarfile.open(archive) as inp:
        actual = {m.name: hashlib.sha256(inp.extractfile(m).read()).hexdigest()
                  for m in inp.getmembers() if m.isfile()}
    assert hashes == actual
    record = {'archive': archive.name, 'sha256': sha(archive), 'members': hashes,
              'reason': 'Lossless compaction after qualification; disk capacity constraint'}
    (folder / 'sta-archive.json').write_text(json.dumps(record, indent=2) + '\n')
    shutil.rmtree(source)
