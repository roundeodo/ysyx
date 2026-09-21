#!/usr/bin/env python3
"""Exercise FENCE.I prediction/maintenance and failed dirty-victim recovery."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import resource
import subprocess

NPC = Path(__file__).resolve().parents[1]


def run(command, log):
    with log.open('w') as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, cwd=NPC)
    if result.returncode:
        raise RuntimeError(f'{log}: exit {result.returncode}\n{log.read_text()[-4000:]}')


def build_image(output, name, template, replacements):
    """Assemble one software scenario and emit the word-oriented RAM image."""
    source = output / f'{name}.S'
    assembly = template.read_text()
    for token, value in replacements.items():
        assembly = assembly.replace(token, value)
    source.write_text(assembly)
    obj, elf, binary = (output / f'{name}.{suffix}' for suffix in ['o', 'elf', 'bin'])
    commands = [
        ('as', ['riscv64-linux-gnu-as', '-march=rv32i_zicsr_zifencei', '-mabi=ilp32',
                '-o', str(obj), str(source)]),
        ('ld', ['riscv64-linux-gnu-ld', '-m', 'elf32lriscv', '-Ttext=0x80000000',
                '-o', str(elf), str(obj)]),
        ('objcopy', ['riscv64-linux-gnu-objcopy', '-O', 'binary', str(elf), str(binary)]),
    ]
    for label, command in commands:
        run(command, output / f'{name}-{label}.log')
    data = binary.read_bytes()
    image = output / f'{name}.hex'
    image.write_text(''.join(f'{int.from_bytes(data[i:i+4], "little"):08x}\n'
                             for i in range(0, len(data), 4)))
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test', choices=['core', 'cache'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rtl-root', type=Path, default=NPC / 'vsrc/riscv32')
    parser.add_argument('defines', nargs='+')
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    output = args.output.resolve() / args.test
    output.mkdir(parents=True, exist_ok=True)
    rtl = args.rtl_root.resolve()
    sources = [rtl / 'common' / name for name in
               ['riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv', 'riscv32_axi4_pkg.sv', 'riscv32_pkg.sv']]
    if args.test == 'core':
        top = 'riscv32_fence_i_tb'
        sources += sorted((rtl / 'core').rglob('*.sv'))
        sources += [NPC / 'tests/exception' / f'{top}.sv']
    else:
        top = 'riscv32_dcache_recovery_tb'
        sources += [rtl / 'core/memory' / f'riscv32_{name}.sv' for name in
                    ['dcache_tag_array', 'dcache_data_array', 'dcache_axi', 'dcache_miss_unit', 'dcache']]
        sources += [NPC / 'tests/rtl' / f'{top}.sv']
    command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
               *args.defines, '--top-module', top, '--Mdir', str(output / 'obj'), *map(str, sources)]
    manifest = {'build': command, 'sources': {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                            for p in sources}, 'cases': []}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    run(command, output / 'build.log')
    binary = str(output / 'obj' / f'V{top}')
    cases = []
    if args.test == 'core':
        patches = {'nop': 0x13, 'addi': 0x00700313, 'load': 0x0009a303,
                   'store': 0x0089a023, 'jal': 0x0040006f, 'csr': 0x34002373, 'illegal': 0xffffffff}
        for name, opcode in patches.items():
            hex_file = build_image(output, name, NPC / 'tests/exception/fence_i_patch.S',
                                   {'PATCH_WORD': hex(opcode)})
            common = [f'+hex={hex_file}', f'+patch_word={opcode:x}']
            if name == 'illegal':
                common += ['+decode_fault=1']
            for schedule, injection in itertools.product(range(4), range(2)):
                cases.append((f'{name}-s{schedule}-inject{injection}', common + [f'+schedule={schedule}', f'+inject={injection}']))
            if name in ['load', 'store']:
                for injection in range(2):
                    cases.append((f'{name}-fault-inject{injection}', common + ['+memory_fault=1', '+schedule=3', f'+inject={injection}']))
            if name == 'nop':
                for error, partial, schedule in itertools.product([2, 3], range(2), range(4)):
                    cases.append((f'clean-{error}-partial{partial}-s{schedule}', common + [f'+clean_fault={error}', f'+partial={partial}', f'+schedule={schedule}']))
        for operation in ['lw t1,256(s1)', 'sw s0,256(s1)']:
            name = 'dirty-' + operation[:2]
            hex_file = build_image(output, name, NPC / 'tests/exception/dirty_victim_trap.S',
                                   {'MISS_INSTRUCTION': operation})
            for partial, schedule in itertools.product(range(2), [0, 3]):
                cases.append((f'{name}-partial{partial}-s{schedule}', [f'+hex={hex_file}', '+patch_word=13', '+dirty_mode=1', f'+partial={partial}', f'+schedule={schedule}']))
    else:
        for fault, delays, partial, store, stall in itertools.product([0, 2, 3], [(0, 0), (25, 0), (0, 25)], range(2), range(2), [0, 4]):
            b_delay, r_delay = delays
            label = f'b{fault}-bd{b_delay}-rd{r_delay}-p{partial}-s{store}-stall{stall}'
            cases.append((label, [f'+fault={fault}', f'+b_delay={b_delay}', f'+r_delay={r_delay}', f'+partial={partial}', f'+store={store}', f'+response_stall={stall}']))
        for fault in [0, 2, 3]:
            cases.append((f'refill-error-b{fault}', [f'+fault={fault}', '+r_error=1', '+b_delay=25', '+response_stall=4', '+store=1']))
    for label, options in cases:
        command = [binary, *options]
        run(command, output / f'{label}.log')
        manifest['cases'].append({'name': label, 'command': command, 'status': 'passed'})
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'PASS {args.test}: {len(cases)} cases')


if __name__ == '__main__':
    main()
