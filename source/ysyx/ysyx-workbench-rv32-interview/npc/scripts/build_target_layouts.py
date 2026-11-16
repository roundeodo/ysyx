#!/usr/bin/env python3
"""Relink the frozen development programs at two predeclared code boundaries."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    a = p.parse_args()
    root = a.root.resolve()
    original = json.loads((root / 'images/manifest.json').read_text())
    for offset in (0x3f00, 0xff00):
        out = root / 'layouts' / f'{offset:04x}'
        out.mkdir(parents=True, exist_ok=False)
        linker = out / 'link.ld'
        linker.write_text('''ENTRY(_start)
SECTIONS {
 . = 0x80000000;
 .start : { *(.text.start) }
 ASSERT(. <= 0x80000100, "startup too large")
 . = CODE_ADDRESS;
 .text : { *(.text*) }
 .rodata : { *(.rodata*) *(.srodata*) }
 .data : { *(.data*) *(.sdata*) }
 .bss : { *(.bss*) *(.sbss*) *(COMMON) }
 . = ALIGN(16);
 _image_end = .;
 _stack_top = 0x80020000;
 ASSERT(_image_end < 0x8001c000, "reserve at least 16 KiB for stack")
}
'''.replace('CODE_ADDRESS', hex(0x80000000 + offset)))
        manifest = dict(original, cases=[])
        manifest['layout'] = {'function_text': hex(0x80000000 + offset), 'startup': '0x80000000',
                              'ram_end': '0x80020000', 'minimum_stack_reserve': 16384,
                              'note': 'Text and following data relocated together; baseline/candidate share image',
                              'linker_sha256': sha(linker)}
        for case in original['cases']:
            if case['held']:
                continue
            folder = out / case['name']
            folder.mkdir()
            old = root / 'images' / case['name']
            command = [str(folder / Path(x).name) if x in [str(old / 'image.elf')] else
                       '-Wl,-Map=' + str(folder / 'image.map') if x.startswith('-Wl,-Map=') else x
                       for x in case['command']]
            command[command.index('-T') + 1] = str(linker)
            with (folder / 'build.log').open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            elf, binary = folder / 'image.elf', folder / 'image.bin'
            subprocess.run(['riscv64-linux-gnu-objcopy', '-O', 'binary', str(elf), str(binary)], check=True)
            data = binary.read_bytes()
            data += b'\0' * (-len(data) % 4)
            (folder / 'image.hex').write_text(''.join(f'{int.from_bytes(data[i:i+4], "little"):08x}\n'
                                                     for i in range(0, len(data), 4)))
            symbols = subprocess.check_output(['riscv64-linux-gnu-nm', str(elf)], text=True)
            addresses = {r.split()[2]: int(r.split()[0], 16) for r in symbols.splitlines() if len(r.split()) == 3}
            assert addresses['_stack_top'] - addresses['_image_end'] > 16384
            assert addresses['run'] >= 0x80000000 + offset
            record = dict(case, command=command, begin_pc=addresses['workload_begin'],
                          end_pc=addresses['workload_end'], image_bytes=len(data),
                          stack_reserve=addresses['_stack_top']-addresses['_image_end'],
                          hashes={f.name: sha(f) for f in (elf, binary, folder/'image.hex')})
            manifest['cases'].append(record)
        (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print('PASS layout build', hex(offset), len(manifest['cases']), flush=True)


if __name__ == '__main__':
    main()
