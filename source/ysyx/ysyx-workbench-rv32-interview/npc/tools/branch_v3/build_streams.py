#!/usr/bin/env python3
"""Freeze distinct real metadata requests and score cold vs cross-request warm."""
import argparse
import ctypes
import hashlib
import json
import re
import subprocess
import zlib
from pathlib import Path

NPC=Path(__file__).resolve().parents[2]
ROOT=NPC/'result/branch-v3'
SOURCE=NPC/'tests/branch_v3'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mix(value, item):
    return ((value*33)^item)&0xffffffff


def tokens(data):
    json.loads(data)
    entries, stack = [], []
    pattern=rb'"(?:\\.|[^"\\])*"|true|false|null|-?\d+(?:\.\d+)?(?:[Ee][+-]?\d+)?|[{}\[\]:,]'
    for match in re.finditer(pattern,data):
        text=match[0]
        if text in (b'{',b'['):
            stack.append(len(entries));entries.append([1 if text==b'{' else 2,match.start(),None])
        elif text in (b'}',b']'):entries[stack.pop()][2]=match.end()
        elif text in (b':',b','):continue
        elif text.startswith(b'"'):entries.append([4,match.start()+1,match.end()-1])
        else:entries.append([8,match.start(),match.end()])
    assert not stack
    return entries


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--split',choices=['development','validation','final'],default='development')
    args=parser.parse_args()
    if args.split == 'final':
        assert (NPC/'docs/research/branch-v3/selection-freeze.json').exists(), 'Freeze selection before final inputs'
    upstream=ROOT/'upstream'
    vocab=upstream/'gpt2-vocab.json'
    # Freeze the source and partition before running any stream candidate.
    source_manifest=SOURCE/'stream-inputs.json'
    record={'url':'https://huggingface.co/openai-community/gpt2/resolve/607a30d783dfa663caf39e06633721c8d4cfcd7e/vocab.json',
            'commit':'607a30d783dfa663caf39e06633721c8d4cfcd7e','sha256':sha(vocab),'license':'MIT',
            'partition':'source-order key ranges: development [0,256), validation [256,512), final [512,768); final not generated',
            'calls':'GPT2 config, BERT config, then four disjoint 64-entry vocabulary metadata objects',
            'limit':'128KiB simulated RAM, 256-token cap per request; vocabulary metadata parsing, not a full BPE tokenizer',
            'windows':'cold measures all six calls; warm measures four different calls after common two-call prefix; not claimed converged'}
    if source_manifest.exists():assert json.loads(source_manifest.read_text())==record
    else:source_manifest.write_text(json.dumps(record,indent=2)+'\n')
    entries=list(json.loads(vocab.read_bytes()).items())
    offset={'development':0, 'validation':256, 'final':512}[args.split]
    raw=[(upstream/(name+'.json')).read_bytes() for name in ['gpt2','bert']]
    raw += [json.dumps(dict(entries[offset+i*64:offset+(i+1)*64]),ensure_ascii=False,separators=(',',':')).encode() for i in range(4)]
    output_root=ROOT/('streams-'+args.split);output_root.mkdir(exist_ok=False)
    manifest={'cases':[],'source':record,'split':args.split,'ram_bytes':131072,'warmup':'each predictor runs its own two real requests; no state transplant'}
    vendor=NPC/'tests/frontend_selection/vendor/miniz'
    helpers=NPC.parent/'abstract-machine/am/src/riscv/npc/libgcc'
    gcc_include=subprocess.check_output(['riscv64-linux-gnu-gcc','-print-file-name=include'],text=True).strip()
    for kind in (0,1):
        data=raw if kind==0 else [zlib.compress(value,6) for value in raw]
        expected=5381
        for original in raw:
            if kind==0:
                parsed=tokens(original);assert len(parsed)<=256
                expected=mix(expected,len(parsed))
                for typ,start,end in parsed:
                    expected=mix(mix(expected,typ),end-start)
                    for byte in original[start:end]:expected=mix(expected,byte)
            else:
                for byte in original:expected=mix(expected,byte)
        for warm in (False,True):
            name=('jsmn_stream' if kind==0 else 'miniz_stream')+('-warm' if warm else '-cold')
            folder=output_root/name;folder.mkdir()
            input_blob=b''.join(data)
            def array(name,values,ctype='unsigned'):
                return f'static const {ctype} {name}[]={{'+','.join(map(str,values))+'};\n'
            prefix=f'#define WORKLOAD {kind}\n#define CALL_COUNT 6\n#define FIRST_MEASURED {2 if warm else 0}\n#define OUTPUT_BYTES {sum(map(len,raw))}\n#define TOKEN_CAPACITY 256\n'
            prefix+=array('input',input_blob,'unsigned char')
            prefix+=array('input_offset',[sum(map(len,data[:i])) for i in range(6)])
            prefix+=array('input_length',list(map(len,data)))
            prefix+=array('raw_length',list(map(len,raw)))
            prefix+=array('output_offset',[sum(map(len,raw[:i])) for i in range(6)])
            (folder/'input.h').write_text(prefix);(folder/'payload.bin').write_bytes(input_blob)
            sources=[SOURCE/'upstream_stream.c']+([vendor/'miniz_tinfl.c'] if kind else [])
            common=['-O2','-fno-builtin','-ffunction-sections','-fdata-sections','-I',str(folder),'-I',str(upstream),'-I',str(vendor),'-DMINIZ_NO_STDIO','-DMINIZ_NO_TIME','-DMINIZ_NO_ARCHIVE_APIS','-DMINIZ_NO_ZLIB_APIS']
            def run(command,log):
                with (folder/log).open('x') as file:subprocess.run(list(map(str,command)),stdout=file,stderr=subprocess.STDOUT,check=True)
            native=['gcc',*common,'-shared','-fPIC','-Wl,-Bsymbolic',*sources,'-o',folder/'native.so']
            run(native,'native.log')
            lib=ctypes.CDLL(str(folder/'native.so'));lib.run.restype=ctypes.c_uint32
            assert lib.run()==expected
            elf,binary=folder/'image.elf',folder/'image.bin'
            command=['riscv64-linux-gnu-gcc',*common,'-march=rv32i_zicsr_zifencei','-mabi=ilp32','-mstrict-align','-msmall-data-limit=0','-fno-pic','-fno-stack-protector','-nostdlib','-nostdinc','-isystem',gcc_include,'-I',str(ROOT/'images/include'),'-static','-Wl,--gc-sections,--build-id=none','-Wl,-Map='+str(folder/'image.map'),'-T',NPC/'tests/frontend_exploration/link.ld',SOURCE/'upstream_stream_start.S',*sources,NPC/'tests/frontend_selection/runtime.c',helpers/'div.S',helpers/'muldi3.S','-o',elf]
            run(command,'build.log');run(['riscv64-linux-gnu-objcopy','-O','binary',elf,binary],'objcopy.log')
            values=binary.read_bytes();values+=b'\0'*(-len(values)%4)
            (folder/'image.hex').write_text(''.join(f'{int.from_bytes(values[i:i+4],"little"):08x}\n' for i in range(0,len(values),4)))
            symbols=subprocess.check_output(['riscv64-linux-gnu-nm',str(elf)],text=True)
            addresses={line.split()[2]:int(line.split()[0],16) for line in symbols.splitlines() if len(line.split())==3}
            manifest['cases'].append({'name':name,'kind':'jsmn' if kind==0 else 'miniz','held':False,'split':args.split,'expected':expected,'begin_pc':addresses['workload_begin'],'end_pc':addresses['workload_end'],'input_bytes':list(map(len,raw)),'token_counts':list(map(lambda value:len(tokens(value)),raw)), 'call_count':6,'warm_prefix_calls':2 if warm else 0,'command':list(map(str,command)),'native_command':list(map(str,native)),'hashes':{p.name:sha(p) for p in (elf,binary,folder/'input.h',folder/'payload.bin')}})
            print('PASS streams native/Python/RV32 build',name,flush=True)
    manifest['sources']={str(path):sha(path) for path in [Path(__file__),SOURCE/'upstream_stream.c',SOURCE/'upstream_stream_start.S',upstream/'jsmn.h',vendor/'miniz_tinfl.c']}
    (output_root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')


if __name__=='__main__':main()
