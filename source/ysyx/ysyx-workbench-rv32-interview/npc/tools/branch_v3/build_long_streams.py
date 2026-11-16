#!/usr/bin/env python3
"""Pre-partitioned 8/32/128-request scaling using distinct upstream vocabulary data."""
import argparse,ctypes,json,subprocess,zlib
from pathlib import Path
from build_streams import sha,mix,tokens,NPC,ROOT,SOURCE

def main():
 p=argparse.ArgumentParser();p.add_argument('--split',choices=['development','validation','final'],default='development');p.add_argument('--paired-windows',action='store_true');a=p.parse_args()
 if a.split=='final':assert (NPC/'docs/research/branch-v3/selection-freeze.json').exists()
 upstream=ROOT/'upstream';vocab=upstream/'gpt2-vocab.json'
 record={'source_sha256':sha(vocab),'source_manifest':'npc/tests/branch_v3/stream-inputs.json',
  'ranges':{'development':[1024,9728],'validation':[17408,26112],'final':[33792,42496]},
  'scales':[8,32,128],'prefix_requests':8,'keys_per_request':64,'RAM_bytes':2097152,
  'scope':'distinct vocabulary metadata requests; parser/decompressor reuse, not full tokenizer/inference',
  'selection':'declared before long-stream candidate results; cold and 8-request prefix both scored; no convergence assumption'}
 if a.paired_windows:record['windows']='One identical binary; cold begin before prefix, warm begin after prefix. No code/layout difference.'
 freeze=SOURCE/('long-stream-paired-inputs.json' if a.paired_windows else 'long-stream-inputs.json')
 if freeze.exists():assert json.loads(freeze.read_text())==record
 else:freeze.write_text(json.dumps(record,indent=2)+'\n')
 out=ROOT/(('streams-long-paired-' if a.paired_windows else 'streams-long-')+a.split);out.mkdir(exist_ok=False)
 startup=SOURCE/('upstream_stream_windows.S' if a.paired_windows else 'upstream_stream_start.S')
 entries=list(json.loads(vocab.read_bytes()).items());start=record['ranges'][a.split][0]
 raw=[json.dumps(dict(entries[start+i*64:start+(i+1)*64]),ensure_ascii=False,separators=(',',':')).encode() for i in range(136)]
 assert all(len(tokens(value))<=256 for value in raw)
 manifest={'cases':[],'split':a.split,'source':record,'ram_bytes':2097152}
 vendor=NPC/'tests/frontend_selection/vendor/miniz';helpers=NPC.parent/'abstract-machine/am/src/riscv/npc/libgcc'
 include=subprocess.check_output(['riscv64-linux-gnu-gcc','-print-file-name=include'],text=True).strip()
 linker=out/'link.ld';linker.write_text((NPC/'tests/frontend_exploration/link.ld').read_text().replace('0x80020000','0x80200000').replace('0x80018000','0x801f0000'))
 for requests in record['scales']:
  originals=raw[:requests+8];count=len(originals)
  for kind in (0,1):
   data=originals if kind==0 else [zlib.compress(value,6) for value in originals];expected=5381
   for original in originals:
    if kind==0:
     parsed=tokens(original);expected=mix(expected,len(parsed))
     for typ,beg,end in parsed:
      expected=mix(mix(expected,typ),end-beg)
      for byte in original[beg:end]:expected=mix(expected,byte)
    else:
     for byte in original:expected=mix(expected,byte)
   for warm in (False,True):
    name=f'{"jsmn" if kind==0 else "miniz"}_long-{requests}-{"warm" if warm else "cold"}'
    folder=out/name;folder.mkdir()
    def array(name,values,ctype='unsigned'):return f'static const {ctype} {name}[]={{'+','.join(map(str,values))+'};\n'
    header=f'#define WORKLOAD {kind}\n#define CALL_COUNT {count}\n#define FIRST_MEASURED {8 if (warm or a.paired_windows) else 0}\n#define OUTPUT_BYTES {sum(map(len,originals))}\n#define TOKEN_CAPACITY 256\n'
    blob=b''.join(data);header+=array('input',blob,'unsigned char')
    header+=array('input_offset',[sum(map(len,data[:i])) for i in range(count)])+array('input_length',map(len,data))+array('raw_length',map(len,originals))+array('output_offset',[sum(map(len,originals[:i])) for i in range(count)])
    (folder/'input.h').write_text(header);(folder/'payload.bin').write_bytes(blob)
    sources=[SOURCE/'upstream_stream.c']+([vendor/'miniz_tinfl.c'] if kind else [])
    common=['-O2','-fno-builtin','-ffunction-sections','-fdata-sections','-I',str(folder),'-I',str(upstream),'-I',str(vendor),'-DMINIZ_NO_STDIO','-DMINIZ_NO_TIME','-DMINIZ_NO_ARCHIVE_APIS','-DMINIZ_NO_ZLIB_APIS']
    def run(command,filename):
     with (folder/filename).open('x') as log:subprocess.run(list(map(str,command)),stdout=log,stderr=subprocess.STDOUT,check=True)
    native=['gcc',*common,'-shared','-fPIC','-Wl,-Bsymbolic',*sources,'-o',folder/'native.so'];run(native,'native.log')
    lib=ctypes.CDLL(str(folder/'native.so'));lib.run.restype=ctypes.c_uint32;assert lib.run()==expected
    elf,binary=folder/'image.elf',folder/'image.bin'
    command=['riscv64-linux-gnu-gcc',*common,'-march=rv32i_zicsr_zifencei','-mabi=ilp32','-mstrict-align','-msmall-data-limit=0','-fno-pic','-fno-stack-protector','-nostdlib','-nostdinc','-isystem',include,'-I',str(ROOT/'images/include'),'-static','-Wl,--gc-sections,--build-id=none','-Wl,-Map='+str(folder/'image.map'),'-T',linker,startup,*sources,NPC/'tests/frontend_selection/runtime.c',helpers/'div.S',helpers/'muldi3.S','-o',elf]
    run(command,'build.log');run(['riscv64-linux-gnu-objcopy','-O','binary',elf,binary],'objcopy.log')
    values=binary.read_bytes();values+=b'\0'*(-len(values)%4)
    (folder/'image.hex').write_text(''.join(f'{int.from_bytes(values[i:i+4],"little"):08x}\n' for i in range(0,len(values),4)))
    syms=subprocess.check_output(['riscv64-linux-gnu-nm',str(elf)],text=True)
    addresses={line.split()[2]:int(line.split()[0],16) for line in syms.splitlines() if len(line.split())==3}
    manifest['cases'].append({'name':name,'held':False,'split':a.split,'expected':expected,'begin_pc':addresses['workload_cold_begin' if a.paired_windows and not warm else 'workload_begin'],'end_pc':addresses['workload_end'],'input_bytes':list(map(len,originals)),'token_counts':[len(tokens(x)) for x in originals],'call_count':count,'warm_prefix_calls':8 if warm else 0,'scored_calls':requests if warm else count,'image_end':addresses['_image_end'],'command':list(map(str,command)),'native_command':list(map(str,native)),'hashes':{f.name:sha(f) for f in (elf,binary,folder/'input.h',folder/'payload.bin',folder/'image.hex')}})
    print('PASS long-stream build/native/reference',name,'input bytes',sum(map(len,originals)),flush=True)
 if a.paired_windows:
  for requests in record['scales']:
   for kind in ['jsmn','miniz']:
    cold=out/f'{kind}_long-{requests}-cold/image.bin';warm=out/f'{kind}_long-{requests}-warm/image.bin'
    assert cold.read_bytes()==warm.read_bytes(), 'Cold/warm machine code differs'
 manifest['sources']={str(f):sha(f) for f in (Path(__file__),SOURCE/'upstream_stream.c',startup,upstream/'jsmn.h',vendor/'miniz_tinfl.c',linker)}
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
if __name__=='__main__':main()
