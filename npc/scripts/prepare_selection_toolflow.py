#!/usr/bin/env python3
"""Pair the measured flow scripts with an existing iEDA/PDK installation."""
import argparse
import json
from pathlib import Path
import shutil

from explore_frontend import NPC, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installed', type=Path, required=True,
                        help='Existing directory containing bin/iEDA and pdk/nangate45')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    installed, out = args.installed.resolve(), args.output.resolve()
    assert (installed / 'bin/iEDA').is_file()
    library = installed / 'pdk/nangate45/lib/Nangate45_typ.lib'
    assert library.is_file()
    source = NPC / 'tools/icache_explore/sta_flow'
    manifest = json.loads((source / 'manifest.json').read_text())
    for relative, digest in manifest['sha256'].items():
        assert sha(source / relative) == digest, relative
    shutil.copytree(source, out)
    (out / 'bin').symlink_to(installed / 'bin', target_is_directory=True)
    (out / 'pdk').symlink_to(installed / 'pdk', target_is_directory=True)
    (out / 'installation.json').write_text(json.dumps({
        'installed': str(installed), 'ieda_sha256': sha(installed / 'bin/iEDA'),
        'liberty_sha256': sha(library), 'scripts_manifest': manifest}, indent=2) + '\n')
    print(out)


if __name__ == '__main__':
    main()
