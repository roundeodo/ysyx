#!/usr/bin/env python3
"""Fixed independent software families; NMS is an application-level holdout."""
import argparse
import configparser
import ctypes
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import subprocess

from build_selection_workloads import headers, mix

NPC = Path(__file__).resolve().parents[1]
TEST = NPC / 'tests/branch_workloads'


def generate(kind, seed, held):
    rng = random.Random(seed)
    if kind == 'regex_tokenizer':
        words = ['model', 'input_tensor', 'runtime', 'token42', 'output', 'temperature',
                 '0', '1024', '31', '=', '{', '}', ':', ',', '(', ')']
        if held:
            words += ['MixedCase', '工具', 'audio_12', '雪', '99999', '-', '/', '\\']
        text = ''.join(rng.choice(words) + rng.choice([' ', '\t', '\n', '  ', ''])
                       for _ in range(72 if held else 40))
        return text.encode()
    if kind == 'ini_config':
        lines = ['; inference runtime metadata', '[runtime]', 'backend = cpu', 'threads = 1']
        for i in range(8 if held else 4):
            lines += ['', f'[tensor_{i}]', f'name = {rng.choice(["input", "weight", "output"])}_{i}',
                      f'dtype = {rng.choice(["int4", "int8", "int32"])}',
                      f'rows = {rng.randrange(1, 256)}', f'cols = {rng.randrange(1, 256)}',
                      f'offset = {rng.randrange(0, 65536)}', '; next tensor']
        return ('\n'.join(lines) + '\n').encode()
    boxes = []
    for i in range(48):
        cluster = rng.randrange(4)
        x, y = cluster * 64 + rng.randrange(48), cluster * 48 + rng.randrange(48)
        boxes.append([x, y, x + rng.randrange(8, 128), y + rng.randrange(8, 128),
                      rng.randrange(1, 1024), rng.randrange(3)])
    return boxes


def reference(kind, payload):
    h = 5381
    for _ in range(2):
        if kind == 'regex_tokenizer':
            pos = 0
            while pos < len(payload):
                for category, pattern in enumerate([rb'[A-Za-z_][A-Za-z_0-9]*', rb'[0-9]+', rb'[ \t\r\n]+'], 1):
                    match = re.match(pattern, payload[pos:])
                    if match:
                        token = match[0]
                        break
                else:
                    category, token = 4, payload[pos:pos+1]
                h = mix(mix(h, category), len(token))
                for byte in token: h = mix(h, byte)
                pos += len(token)
        elif kind == 'ini_config':
            parser = configparser.ConfigParser(interpolation=None)
            parser.optionxform = str
            parser.read_string(payload.decode())
            for section in parser.sections():
                for key, value in parser[section].items():
                    for text in [section, key, value]:
                        for byte in text.encode(): h = mix(h, byte)
                        h = mix(h, 0)
                    if value and value[0].isdigit(): h = mix(h, int(re.match(r'\d+', value)[0]))
        else:
            remaining = sorted(range(len(payload)), key=lambda i: (-payload[i][4], i))
            while remaining:
                best = remaining.pop(0); b = payload[best]
                h = mix(mix(h, best), b[4])
                kept = []
                for i in remaining:
                    a = payload[i]
                    overlap = max(0, min(a[2],b[2])-max(a[0],b[0])) * max(0,min(a[3],b[3])-max(a[1],b[1]))
                    union = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - overlap
                    if a[5] != b[5] or overlap * 4 <= union: kept.append(i)
                remaining = kept
    return h


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--base-images', type=Path, help='Reuse the twelve hash-checked original-family images')
    parser.add_argument('--dev-seeds', type=int, nargs=2, default=[131, 257])
    parser.add_argument('--held-seeds', type=int, nargs=2, default=[521, 1031])
    args = parser.parse_args(); out = args.output.resolve()
    if len(set(args.dev_seeds + args.held_seeds)) != 4:
        parser.error('Development and held seeds must be distinct')
    # Existing families keep the same implementations but receive fresh inputs.
    if args.base_images:
        previous = args.base_images.resolve()
        manifest = json.loads((previous/'manifest.json').read_text())
        assert len(manifest['cases']) == 12
        out.mkdir(parents=True, exist_ok=False)
        shutil.copytree(previous/'include', out/'include')
        for case in manifest['cases']:
            assert case['seed'] in (args.held_seeds if case['held'] else args.dev_seeds)
            for name,digest in case['hashes'].items():
                assert hashlib.sha256((previous/case['name']/name).read_bytes()).hexdigest() == digest
            shutil.copytree(previous/case['name'], out/case['name'])
        manifest['reused_base_images'] = str(previous)
    else:
        subprocess.run(['python3', str(NPC/'scripts/build_selection_workloads.py'), '--output', str(out),
                        '--dev-seeds', *map(str, args.dev_seeds), '--held-seeds', *map(str, args.held_seeds)], check=True)
        manifest = json.loads((out/'manifest.json').read_text())
    includes = out/'include'
    with (includes/'ctype.h').open('a') as f: f.write('int isspace(int); int isdigit(int); int isalpha(int); int isalnum(int);\n')
    with (includes/'string.h').open('a') as f: f.write('char *strchr(const char *,int);\n')
    with (includes/'stdio.h').open('a') as f: f.write('char *fgets(char *,int,FILE *); FILE *fopen(const char *,const char *); int fclose(FILE *);\n')
    gcc_include = subprocess.check_output(['riscv64-linux-gnu-gcc','-print-file-name=include'],text=True).strip()
    helpers = NPC.parent/'abstract-machine/am/src/riscv/npc/libgcc'
    for held,seeds in [(False,args.dev_seeds),(True,args.held_seeds)]:
        for kind_id,kind in enumerate(['regex_tokenizer','ini_config','nms_postprocess']):
            if kind_id == 2 and not held: continue
            for seed in seeds:
                name=f'{kind}-{"held" if held else "dev"}-{seed}'; folder=out/name;folder.mkdir()
                payload=generate(kind,seed,held);expected=reference(kind,payload)
                content=f'#define WORKLOAD {kind_id}\n#define REPEATS 2\n'
                if kind_id<2:
                    content+='static const unsigned char input[] = {'+','.join(map(str,payload+b'\0'))+'};\n'
                    (folder/'payload.bin').write_bytes(payload)
                else:
                    content+=f'#define BOX_COUNT {len(payload)}\nstatic const int boxes[][6] = '+'{'+','.join('{'+','.join(map(str,b))+'}' for b in payload)+'};\n'
                    (folder/'payload.json').write_text(json.dumps(payload)+'\n')
                (folder/'input.h').write_text(content)
                sources=[TEST/'workload.c']
                if kind_id<2:sources += [TEST/'vendor'/(['tiny-regex-c/re.c','inih/ini.c'][kind_id])]
                common=['-O2','-fno-builtin','-ffunction-sections','-fdata-sections','-I',str(folder),
                        '-I',str(TEST/'vendor/tiny-regex-c'),'-I',str(TEST/'vendor/inih'),
                        '-DINI_ALLOW_MULTILINE=0','-DINI_ALLOW_INLINE_COMMENTS=0','-DINI_ALLOW_BOM=0']
                def run(command,log):
                    with (folder/log).open('x') as stream:subprocess.run(list(map(str,command)),stdout=stream,stderr=subprocess.STDOUT,check=True)
                native=['gcc',*common,'-shared','-fPIC','-Wl,-Bsymbolic',*sources,'-o',folder/'native.so'];run(native,'native.log')
                library=ctypes.CDLL(str(folder/'native.so'));library.run.restype=ctypes.c_uint32
                actual=library.run();assert actual==expected,(name,hex(actual),hex(expected))
                elf=folder/'image.elf';binary=folder/'image.bin'
                command=['riscv64-linux-gnu-gcc',*common,'-march=rv32i_zicsr_zifencei','-mabi=ilp32','-mstrict-align',
                         '-msmall-data-limit=0','-fno-pic','-fno-stack-protector','-nostdlib','-nostdinc','-isystem',gcc_include,
                         '-I',includes,'-static','-Wl,--gc-sections,--build-id=none','-Wl,-Map='+str(folder/'image.map'),
                         '-T',NPC/'tests/frontend_exploration/link.ld',NPC/'tests/frontend_exploration/start.S',*sources,
                         NPC/'tests/frontend_selection/runtime.c',TEST/'support.c',helpers/'div.S',helpers/'muldi3.S','-o',elf]
                run(command,'build.log');run(['riscv64-linux-gnu-objcopy','-O','binary',elf,binary],'objcopy.log')
                data=binary.read_bytes();data += b'\0' * (-len(data) % 4)
                (folder/'image.hex').write_text(''.join(f'{int.from_bytes(data[i:i+4],"little"):08x}\n' for i in range(0,len(data),4)))
                symbols=subprocess.check_output(['riscv64-linux-gnu-nm',str(elf)],text=True)
                addresses={r.split()[2]:int(r.split()[0],16) for r in symbols.splitlines() if len(r.split())==3}
                manifest['cases'].append({'name':name,'kind':kind,'seed':seed,'held':held,'expected':expected,
                    'begin_pc':addresses['workload_begin'],'end_pc':addresses['workload_end'],'image_bytes':len(data),
                    'command':list(map(str,command)),'native_command':list(map(str,native)),
                    'hashes':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [elf,binary,folder/'input.h']}})
                print('PASS independent reference/native/build',name,len(data),flush=True)
    source_inputs = [Path(__file__), NPC/'scripts/build_selection_workloads.py',
        NPC/'tests/frontend_exploration/start.S', NPC/'tests/frontend_exploration/link.ld',
        NPC/'tests/frontend_selection/runtime.c', helpers/'div.S', helpers/'muldi3.S',
        TEST/'workload.c', TEST/'support.c', *sorted((TEST/'vendor').rglob('*'))]
    for p in source_inputs:
        if p.is_file():manifest['sources'][str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
    manifest['tools'] = {tool: subprocess.check_output([tool, '--version'], text=True).splitlines()[0]
        for tool in ['gcc', 'riscv64-linux-gnu-gcc', 'riscv64-linux-gnu-objcopy', 'riscv64-linux-gnu-nm']}
    manifest['generated_headers'] = {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(includes.glob('*.h'))}
    manifest['held_policy']='NMS is excluded from development; no held performance execution before selection freeze; prior studies may have evaluated this family'
    manifest['seeds']={'development': args.dev_seeds, 'held': args.held_seeds}
    manifest['weights']='equal per family, equal per input within family'
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')


if __name__=='__main__':main()
