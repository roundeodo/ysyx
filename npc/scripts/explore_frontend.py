#!/usr/bin/env python3
"""Reproducible RV32 CPU proxy experiment; held-out execution requires --held-out."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import resource
import subprocess

NPC = Path(__file__).resolve().parents[1]
TEST = NPC / 'tests/frontend_exploration'
MASK = (1 << 32) - 1
VOCAB = 'model token input output sample cache tensor layer true false load store decode prefill queue wait'.split()


def mix(h, x):
    return ((h * 33) ^ x) & MASK


def make_input(kind, seed, held):
    rng = random.Random(seed)
    if kind == 0:
        choices = VOCAB + ['unknown_id', 'sequence9', '123', '7', '{', '}', ':', ',']
        if held:
            choices += ['MixedCase', 'long_identifier_123', '\n', '99999', '(', ')'] * 3
        return (' '.join(rng.choice(choices) for _ in range(96 if held else 48))).encode()
    if kind == 1:
        return bytes(rng.randrange(256) for _ in range(512 if held else 128))
    # Development: short recurring command phases; held: larger mixed queue.
    return bytes((rng.randrange(256) if held else (rng.randrange(32) << 3) | ((i >> 3) & 7))
                 for i in range(384 if held else 96))


def reference(kind, data, repeats):
    h = 5381
    state = list(range(1, 9))
    for _ in range(repeats):
        if kind == 0:
            for token in re.findall(rb'[A-Za-z_][A-Za-z_0-9]*|[0-9]+|[^\s]', data):
                if chr(token[0]).isalpha() or token[0] == 95:
                    word = 0
                    for c in token:
                        word = mix(word, c)
                    text = token.decode()
                    h = mix(mix(h, VOCAB.index(text) if text in VOCAB else 256), word)
                elif 48 <= token[0] <= 57:
                    h = mix(mix(h, 257), int(token) & MASK)
                else:
                    h = mix(h, token[0])
        elif kind == 1:
            values = []
            for i, v in enumerate(data):
                a, b = (v & 15) - (16 if v & 8 else 0), (v >> 4) - (16 if v & 128 else 0)
                values += [max(-24, min(23, a * 4 + (i & 7) - 3)),
                           max(-24, min(23, b * 4 - (i & 7) + 3))]
            for block in range(0, len(values), 32):
                for lane in range(4):
                    for row in range(8):
                        h = mix(h, values[block + 4 * row + lane] & 255)
        else:
            for v in data:
                slot, op = (v >> 3) & 7, v & 7
                x, y = state[slot], ((v >> 2) + state[(slot + 1) & 7]) & MASK
                values = [x+y, x^(y<<3), x+7 if x<y else x-y, (x>>1)|(y<<24),
                          x+1 if (x&255)==y else x^y, (x<<2)+y,
                          x+y if x&1 else x-y, (x>>3)^(y+17)]
                state[slot] = values[op] & MASK
                h = mix(h, state[slot])
    return h


def run(command, log):
    with log.open('w') as stream:
        result = subprocess.run(list(map(str, command)), cwd=NPC, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{log}: exit {result.returncode}\n{log.read_text()[-5000:]}')


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def build_images(output):
    output.mkdir(parents=True, exist_ok=False)
    cases = []
    for held, seeds in [(False, [11, 23]), (True, [101, 307])]:
        for kind, name in enumerate(['tokenizer', 'int4', 'runtime']):
            for seed in seeds:
                label = f'{name}-{"held" if held else "dev"}-{seed}'
                directory = output / label
                directory.mkdir()
                data = make_input(kind, seed, held)
                repeats = 3
                (directory / 'input.h').write_text(
                    f'#define WORKLOAD {kind}\n#define REPEATS {repeats}\n#define INPUT_COUNT {len(data)}\n'
                    + 'static const unsigned char input[] = {' + ','.join(map(str, data)) + '};\n')
                elf, binary = directory / 'image.elf', directory / 'image.bin'
                command = ['riscv64-linux-gnu-gcc', '-march=rv32i_zicsr_zifencei', '-mabi=ilp32',
                           '-O2', '-fno-builtin', '-fno-pic', '-fno-stack-protector', '-fno-jump-tables',
                           '-msmall-data-limit=0', '-nostdlib', '-static', '-Wl,--build-id=none',
                           '-Wl,-Map=' + str(directory / 'image.map'), '-T', TEST / 'link.ld',
                           '-I', directory, TEST / 'start.S', TEST / 'proxy.c', '-o', elf]
                run(command, directory / 'build.log')
                run(['riscv64-linux-gnu-objcopy', '-O', 'binary', elf, binary], directory / 'objcopy.log')
                contents = binary.read_bytes()
                (directory / 'image.hex').write_text(''.join(f'{int.from_bytes(contents[i:i+4], "little"):08x}\n'
                                                            for i in range(0, len(contents), 4)))
                symbols = subprocess.check_output(['riscv64-linux-gnu-nm', str(elf)], text=True)
                addresses = {line.split()[2]: int(line.split()[0], 16) for line in symbols.splitlines() if len(line.split()) == 3}
                cases.append({'name': label, 'kind': name, 'held': held, 'seed': seed, 'repeats': repeats,
                              'expected': reference(kind, data, repeats), 'begin_pc': addresses['workload_begin'],
                              'end_pc': addresses['workload_end'], 'image_bytes': len(contents), 'command': list(map(str, command)),
                              'hashes': {str(p.name): sha(p) for p in [elf, binary, directory / 'input.h']}})
    manifest = {'cases': cases, 'sources': {str(p): sha(p) for p in [TEST / 'proxy.c', TEST / 'start.S', TEST / 'link.ld', Path(__file__)]},
                'weights': 'equal per kind; equal inputs within kind', 'held_policy': 'global parameters frozen before first held run'}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


def build_rtl(output, rtl, defines, host_opt=0):
    output.mkdir(parents=True, exist_ok=False)
    sources = [rtl / 'common' / n for n in ['riscv_config_pkg.sv', 'riscv32_addr_map_pkg.sv', 'riscv32_axi4_pkg.sv', 'riscv32_pkg.sv']]
    sources += sorted((rtl / 'core').rglob('*.sv'))
    sources += [rtl / 'system/riscv32_axi4_arbiter.sv', TEST / 'axi_memory.sv', TEST / 'core_tb.sv']
    settings = {'YSYX_RV32_BASELINE': None, 'YSYX_ICACHE_CAPACITY_BYTES': 256, 'YSYX_ICACHE_WAY_COUNT': 1,
                'YSYX_ICACHE_LINE_BYTES': 16, 'YSYX_DCACHE_ENABLE': 1, 'YSYX_DCACHE_CAPACITY_BYTES': 256,
                'YSYX_DCACHE_WAY_COUNT': 2, 'YSYX_DCACHE_LINE_BYTES': 16, 'YSYX_BRANCH_HISTORY_ENTRY_COUNT': 16,
                'YSYX_BRANCH_TARGET_ENTRY_COUNT': 16, 'YSYX_BRANCH_TARGET_WAY_COUNT': 2, 'YSYX_RETURN_STACK_ENTRY_COUNT': 4}
    for define in defines:
        key, value = define.split('=', 1)
        settings[key] = value
    command = ['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-j', '2',
               '-MAKEFLAGS', f'OPT_FAST=-O{host_opt} OPT_SLOW=-O{host_opt} OPT_GLOBAL=-O{host_opt}',
               '--top-module', 'exploration_core_tb', '--Mdir', str(output / 'obj')]
    command += ['+define+' + k + (f'={v}' if v is not None else '') for k, v in settings.items()]
    command += list(map(str, sources))
    (output / 'manifest.json').write_text(json.dumps({'command': command, 'settings': settings,
        'sources': {str(p): sha(p) for p in sources}, 'memory_modes': ['cycle', 'physical']}, indent=2) + '\n')
    run(command, output / 'build.log')


def simulate(args):
    memory_mode = getattr(args, 'memory_mode', 'cycle')
    build_manifest = args.binary.parent.parent / 'manifest.json'
    supported = json.loads(build_manifest.read_text()).get('memory_modes', ['cycle'])
    assert memory_mode in supported, 'Rebuild simulator for requested memory mode'
    args.output.mkdir(parents=True, exist_ok=False)
    cases = json.loads((args.images / 'manifest.json').read_text())['cases']
    results = []
    for case in cases:
        if case['held'] != args.held_out:
            continue
        label = case['name']
        image_dir = args.images / label
        for name, expected in case['hashes'].items():
            assert sha(image_dir / name) == expected
        # The simulator consumes HEX, so bind that serialization to the hashed binary.
        contents = (image_dir / 'image.bin').read_bytes()
        expected_hex = ''.join(f'{int.from_bytes(contents[i:i+4], "little"):08x}\n'
                               for i in range(0, len(contents), 4))
        assert (image_dir / 'image.hex').read_text() == expected_hex, 'HEX differs from frozen binary'
        command = [args.binary, f'+image={image_dir / "image.hex"}', f'+begin_pc={case["begin_pc"]:x}',
                   f'+end_pc={case["end_pc"]:x}', f'+expected={case["expected"]:x}', f'+cpu_mhz={args.mhz}',
                   f'+latency_ns={args.latency_ns}', f'+beat_ns={args.beat_ns}', '+seed=97531',
                   f'+memory_mode={memory_mode}',
                   f'+random_stalls={int(args.random_stalls)}', f'+observer={int(not args.no_observer)}']
        if not args.no_observer and not getattr(args, 'no_trace', False):
            command += [f'+trace={args.output / (label + ".trace")}', f'+fetch_trace={args.output / (label + ".fetch")}']
        log = args.output / (label + '.log')
        run(command, log)
        text = log.read_text()
        assert 'PASS proxy' in text
        result = dict(re.findall(r'(\w+)=([0-9a-f]+)', re.search(r'^RESULT .+$', text, re.M)[0]))
        result = {k: int(v, 16 if k in ['digest', 'checksum'] else 10) for k, v in result.items()}
        counters = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', re.search(r'^COUNTERS .+$', text, re.M)[0])}
        detail = re.search(r'^DETAIL .+$', text, re.M)
        if detail:
            counters.update({k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', detail[0])})
        results.append({'case': case, 'result': result, 'counters': counters, 'command': list(map(str, command)),
                        'seconds': result['cycles'] / (args.mhz * 1e6), 'ipc': result['retired'] / result['cycles']})
        # Qualification watchers must never observe a half-written JSON record.
        pending = args.output / 'results.json.tmp'
        pending.write_text(json.dumps({'mhz': args.mhz, 'latency_ns': args.latency_ns,
            'beat_ns': args.beat_ns, 'random_stalls': args.random_stalls, 'memory_mode': memory_mode, 'binary_sha256': sha(args.binary), 'results': results}, indent=2) + '\n')
        pending.replace(args.output / 'results.json')
        print(label, result['cycles'], counters['misses'], flush=True)


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['images', 'build', 'run'])
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--rtl', type=Path, default=NPC / 'vsrc/riscv32')
    p.add_argument('--define', action='append', default=[])
    p.add_argument('--images', type=Path)
    p.add_argument('--binary', type=Path)
    p.add_argument('--held-out', action='store_true')
    p.add_argument('--no-observer', action='store_true')
    p.add_argument('--no-trace', action='store_true', help='Keep passive counters; omit per-instruction files')
    p.add_argument('--random-stalls', action='store_true')
    p.add_argument('--memory-mode', choices=['cycle', 'physical'], default='cycle')
    p.add_argument('--mhz', type=int, default=580)
    p.add_argument('--latency-ns', type=int, default=100)
    p.add_argument('--beat-ns', type=int, default=10)
    a = p.parse_args()
    for key in ['output', 'rtl', 'images', 'binary']:
        if getattr(a, key): setattr(a, key, getattr(a, key).resolve())
    if a.action == 'images': build_images(a.output)
    elif a.action == 'build': build_rtl(a.output, a.rtl, a.define)
    else: simulate(a)


if __name__ == '__main__':
    main()
