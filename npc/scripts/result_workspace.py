"""Bounded generated workspaces: lock, retain small reports, reuse, then prune."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
from datetime import datetime, timezone
from uuid import uuid4

MARKER = '.npc-generated-workspace'
SKIP = {'build', 'source', 'baseline', 'obj', 'sta'}


def assert_idle(root):
    """Also protect tasks started before this lock convention was introduced."""
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit() or int(proc.name) == os.getpid():
            continue
        try:
            links = [proc/'exe', proc/'cwd', *list((proc/'fd').iterdir())]
            for link in links:
                try:
                    target = Path(os.readlink(link).removesuffix(' (deleted)'))
                    if target.is_absolute() and target.is_relative_to(root):
                        raise RuntimeError(f'Workspace is in use by PID {proc.name}: {root}')
                except OSError:
                    pass
        except (FileNotFoundError, PermissionError):
            continue


class ResultWorkspace:
    def __init__(self, npc, root, kind, *, resume=False, keep=False):
        self.npc = Path(npc).resolve()
        self.root = Path(root).resolve()
        if not self.root.is_relative_to(self.npc/'result') or self.root == self.npc/'result':
            raise ValueError('Managed output must be a subdirectory of npc/result')
        self.kind, self.resume, self.keep = kind, resume, keep
        self.lock = None
        self.history = None

    def __enter__(self):
        locks = self.npc/'build/locks'
        locks.mkdir(parents=True, exist_ok=True)
        key = hashlib.sha256(str(self.root).encode()).hexdigest()[:20]
        self.lock = (locks/f'result-{key}.lock').open('a')
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert_idle(self.root)
            if self.resume and not self.root.is_dir():
                raise ValueError(f'Resume workspace does not exist: {self.root}')
            if self.root.exists() and not self.resume:
                if not (self.root/MARKER).is_file():
                    raise ValueError(f'Refusing to overwrite an unmanaged directory: {self.root}')
                self.archive('previous')
                shutil.rmtree(self.root)
            self.root.mkdir(parents=True, exist_ok=True)
            (self.root/MARKER).write_text('NPC generated scratch; reports retained before reuse.\n')
            return self
        except BaseException:
            self.lock.close()
            raise

    def archive(self, status):
        # Never copy netlist JSON, source snapshots, build objects or full logs.
        candidates = []
        for p in self.root.rglob('*'):
            rel = p.relative_to(self.root)
            if p.is_symlink() or not p.is_file() or any(
                    part in SKIP or part.startswith('obj_dir') for part in rel.parts):
                continue
            if p.name == 'retention.json':
                continue
            compact = p.suffix in {'.json', '.md', '.csv'} or (rel.parts[0] == 'analysis' and p.suffix in {'.rpt', '.txt'})
            if compact and p.stat().st_size <= 2*1024*1024:
                candidates.append((p, rel))
        if not candidates:
            return
        # Avoid archiving the same finished run again on the next invocation.
        if status == 'previous' and (self.root/'retention.json').exists():
            return
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        history = self.npc/'docs/verification/data/run-history'/f'{stamp}-{self.kind}-{uuid4().hex[:8]}'
        history.mkdir(parents=True)
        for p, rel in candidates:
            q = history/rel
            q.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, q)
        metadata = {'status': status, 'command': sys.argv, 'workspace': str(self.root),
                    'retention': 'compact reports only; generated binaries, source snapshots and netlists are disposable'}
        (history/'run.json').write_text(json.dumps(metadata, indent=2)+'\n')
        lines = [f'# {self.kind}: {status}', '', 'Command: `'+' '.join(sys.argv)+'`', '']
        for path in sorted(history.rglob('*.json')):
            if path.name not in {'qualified.json', 'report.json', 'summary.json'}:
                continue
            value = json.loads(path.read_text())
            keys = ['mhz', 'area_um2', 'all_groups_passed', 'scale', 'isa', 'cpu_mhz', 'timing_model', 'total', 'scored']
            lines += [f'- {key}: `{json.dumps(value[key], ensure_ascii=False)}`' for key in keys if key in value]
        (history/'README.md').write_text('\n'.join(lines)+'\n')
        self.history = history
        (self.root/'retention.json').write_text(json.dumps({'history': str(history), 'status':status,
            'full_artifacts_kept':self.keep or status != 'complete'}, indent=2)+'\n')
        print(f'Analysis: {history}', flush=True)

    def __exit__(self, kind, value, traceback):
        try:
            self.archive('failed' if kind else 'complete')
            # A prepared image must remain executable for --resume. Failure keeps
            # the latest workspace for diagnosis; the next invocation replaces it.
            if kind is None and not self.keep:
                assert_idle(self.root)
                heavy = [p for p in self.root.rglob('*') if p.name in {'build', 'source', 'sta'}
                         and p.is_dir() and not p.is_symlink()]
                for p in sorted(heavy, key=lambda p: len(p.parts), reverse=True):
                    shutil.rmtree(p)
                for name in ['simulator', 'source-snapshot.tar.gz']:
                    (self.root/name).unlink(missing_ok=True)
                for p in self.root.rglob('*.log'):
                    if p.is_symlink() or p.stat().st_size <= 65536:
                        continue
                    with p.open('rb') as stream:
                        stream.seek(-65536, 2)
                        tail = stream.read()
                    p.write_bytes(b'[older log text discarded by retention policy]\n'+tail)
        finally:
            self.lock.close()
        return False
