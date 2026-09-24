#!/usr/bin/env python3
"""One bounded auxiliary PPA worker; publish completed references atomically."""
import argparse
import ctypes
import errno
import json
from pathlib import Path
import shutil

from select_icache_ppa import qualify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--configs', nargs='+', required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    for name in args.configs:
        target = root / 'ppa' / name
        if target.exists():
            continue
        auxiliary = root / 'ppa-aux' / name
        qualify(name, root / 'ppa-aux', resume=True)
        staging = root / 'ppa-aux' / (name + '-reference')
        staging.mkdir(exist_ok=True)
        for filename in ['cells.json', 'timing.json', 'source-hashes.json']:
            shutil.copy2(auxiliary / filename, staging / filename)
        result = json.loads((auxiliary / 'qualified.json').read_text())
        result['original_artifacts'] = str(auxiliary)
        result['reuse_evidence'] = 'Identical declared configuration; independent frozen source snapshot; auxiliary worker'
        (staging / 'qualified.json').write_text(json.dumps(result, indent=2) + '\n')
        # RENAME_NOREPLACE never overwrites even an empty directory that the main
        # worker has just created. The reference becomes visible as one unit.
        libc = ctypes.CDLL(None, use_errno=True)
        status = libc.renameat2(-100, str(staging).encode(), -100, str(target).encode(), 1)
        if status:
            assert ctypes.get_errno() == errno.EEXIST, ctypes.get_errno()
            print('Main worker already claimed', name, flush=True)
        else:
            print('Published completed reference', name, flush=True)


if __name__ == '__main__':
    main()
