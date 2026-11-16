#!/usr/bin/env python3
"""Build independent native/Python/RV32 checks on frozen real model metadata."""
import ctypes,hashlib,json,re,shutil,subprocess,sys,zlib
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];sys.path.insert(0,str(NPC/'scripts'))
from build_selection_workloads import mix
root=NPC/'result/branch-v3';up=root/'upstream';out=root/'real-images-v2';out.mkdir(exist_ok=False)
metadata=json.loads((up/'manifest.json').read_text())
for r in metadata:
 file=up/(r['name']+'.json' if r['name'] in ('bert','gpt2') else r['name'])
 assert hashlib.sha256(file.read_bytes()).hexdigest()==r['sha256']
inc=root/'images/include';helpers=NPC.parent/'abstract-machine/am/src/riscv/npc/libgcc'
gccinc=subprocess.check_output(['riscv64-linux-gnu-gcc','-print-file-name=include'],text=True).strip()
manifest={'cases':[],'source_inputs':metadata,'scope':'development; existing 128KiB RAM; model metadata only; no held input'}
def tokens(data):
 json.loads(data)
 entries=[];stack=[]
 pattern=rb'"(?:\\.|[^"\\])*"|true|false|null|-?\d+(?:\.\d+)?(?:[Ee][+-]?\d+)?|[{}\[\]:,]'
 for m in re.finditer(pattern,data):
  text=m[0]
  if text in (b'{',b'['):
   stack.append(len(entries));entries.append([1 if text==b'{' else 2,m.start(),None])
  elif text in (b'}',b']'):entries[stack.pop()][2]=m.end()
  elif text in (b':',b','):continue
  elif text.startswith(b'"'):entries.append([4,m.start()+1,m.end()-1])
  else:entries.append([8,m.start(),m.end()])
 assert not stack
 return entries
for kind in [0,1]:
 for model in ['gpt2','bert']:
  raw=(up/(model+'.json')).read_bytes();data=raw if kind==0 else zlib.compress(raw,6)
  name=('jsmn_config' if kind==0 else 'miniz_metadata')+'-'+model
  folder=out/name;folder.mkdir();repeats=3
  h=5381
  for repeat in range(repeats):
   if kind==0:
    ts=tokens(raw);h=mix(h,len(ts))
    for typ,start,end in ts:
     h=mix(mix(h,typ),end-start)
     for byte in raw[start:end]:h=mix(h,byte)
   else:
    assert zlib.decompress(data)==raw
    for byte in raw:h=mix(h,byte)
  (folder/'input.h').write_text(f'#define WORKLOAD {kind}\n#define REPEATS {repeats}\n#define INPUT_BYTES {len(data)}\n#define RAW_BYTES {len(raw)}\nstatic const unsigned char input[]={{'+','.join(map(str,data+b'\0'))+'};\n')
  (folder/'payload.bin').write_bytes(data)
  sources=[NPC/'tests/branch_v3/upstream_workload.c']
  if kind==1:sources+=[NPC/'tests/frontend_selection/vendor/miniz/miniz_tinfl.c']
  common=['-O2','-fno-builtin','-ffunction-sections','-fdata-sections','-I',str(folder),'-I',str(up),'-I',str(NPC/'tests/frontend_selection/vendor/miniz'),'-DMINIZ_NO_STDIO','-DMINIZ_NO_TIME','-DMINIZ_NO_ARCHIVE_APIS','-DMINIZ_NO_ZLIB_APIS']
  def run(cmd,log):
   with (folder/log).open('x') as f:subprocess.run(list(map(str,cmd)),stdout=f,stderr=subprocess.STDOUT,check=True)
  native=['gcc',*common,'-shared','-fPIC','-Wl,-Bsymbolic',*sources,'-o',folder/'native.so'];run(native,'native.log')
  library=ctypes.CDLL(str(folder/'native.so'));library.run.restype=ctypes.c_uint32
  actual=library.run();assert actual==h,(name,actual,h)
  elf=folder/'image.elf';binary=folder/'image.bin'
  command=['riscv64-linux-gnu-gcc',*common,'-march=rv32i_zicsr_zifencei','-mabi=ilp32','-mstrict-align','-msmall-data-limit=0','-fno-pic','-fno-stack-protector','-nostdlib','-nostdinc','-isystem',gccinc,'-I',str(inc),'-static','-Wl,--gc-sections,--build-id=none','-Wl,-Map='+str(folder/'image.map'),'-T',NPC/'tests/frontend_exploration/link.ld',NPC/'tests/branch_v3/upstream_start.S',*sources,NPC/'tests/frontend_selection/runtime.c',helpers/'div.S',helpers/'muldi3.S','-o',elf]
  run(command,'build.log');run(['riscv64-linux-gnu-objcopy','-O','binary',elf,binary],'objcopy.log')
  data=binary.read_bytes();data+=b'\0'*(-len(data)%4)
  (folder/'image.hex').write_text(''.join(f'{int.from_bytes(data[i:i+4],"little"):08x}\n' for i in range(0,len(data),4)))
  symbols=subprocess.check_output(['riscv64-linux-gnu-nm',str(elf)],text=True);addr={r.split()[2]:int(r.split()[0],16) for r in symbols.splitlines() if len(r.split())==3}
  manifest['cases'].append({'name':name,'kind':'jsmn_config' if kind==0 else 'miniz_metadata','held':False,'expected':h,'begin_pc':addr['workload_begin'],'end_pc':addr['workload_end'],'image_bytes':len(data),'input_bytes':len(raw),'command':list(map(str,command)),'native_command':list(map(str,native)),'hashes':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [elf,binary,folder/'input.h',folder/'payload.bin']}})
  print('PASS Python/native/build',name,len(data),flush=True)
manifest['sources']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),NPC/'tests/branch_v3/upstream_workload.c',up/'jsmn.h',NPC/'tests/frontend_selection/vendor/miniz/miniz_tinfl.c']}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
