#!/usr/bin/env python3
"""Verify independent rebuilds, including load bytes, accounting windows and symbols."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def normalized_elf(path):
    text = subprocess.check_output(['riscv64-linux-gnu-readelf', '-a', str(path)], text=True)
    # GCC's assembler temporary input name is a non-loaded STT_FILE symbol.
    return re.sub(r'(FILE\s+LOCAL\s+DEFAULT\s+ABS )cc[A-Za-z0-9]+\.o', r'\1<compiler-temporary>.o', text)


def main():
    p = argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    a = p.parse_args();root=a.root.resolve()
    original=json.loads((root/'images/manifest.json').read_text())
    rebuilt=json.loads((root/'images-reproduction/manifest.json').read_text())
    expected={c['name']:c for c in original['cases']};actual={c['name']:c for c in rebuilt['cases']}
    assert set(expected)==set(actual) and len(expected)==22
    for name, case in expected.items():
        for filename,digest in case['hashes'].items():
            if filename!='image.elf':assert digest==actual[name]['hashes'][filename],(name,filename)
        assert normalized_elf(root/'images'/name/'image.elf')==normalized_elf(root/'images-reproduction'/name/'image.elf'),name
        for key in ['begin_pc','end_pc','expected','image_bytes','held','kind','seed']:
            assert case[key]==actual[name][key],(name,key)
        assert (root/'images'/name/'image.hex').read_bytes()==(root/'images-reproduction'/name/'image.hex').read_bytes()
    (root/'image-reproduction.json').write_text(json.dumps({'status':'passed','cases':22,'seeds':original['seeds'],
        'binary_input_and_hex_equal':True,'elf_readelf_equal_except_STT_FILE_temporary_names':True,
        'note':'Raw ELF hashes differ only because GCC assembler temporary file names appear in non-loaded STT_FILE symbols; both raw files retained'},indent=2)+'\n')
    print('PASS 22 software image reproductions')


if __name__=='__main__':main()
