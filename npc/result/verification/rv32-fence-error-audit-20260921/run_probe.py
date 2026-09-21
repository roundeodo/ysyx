from pathlib import Path
import subprocess,json,hashlib
out=Path(__file__).resolve().parent
npc=out.parents[2]
rtl=npc/'vsrc/riscv32'
# Match rv32-baseline Makefile values explicitly.
macros={'YSYX_RV32_BASELINE':None,'YSYX_ICACHE_CAPACITY_BYTES':256,'YSYX_ICACHE_WAY_COUNT':1,'YSYX_ICACHE_LINE_BYTES':16,'YSYX_DCACHE_ENABLE':1,'YSYX_DCACHE_CAPACITY_BYTES':256,'YSYX_DCACHE_WAY_COUNT':2,'YSYX_DCACHE_LINE_BYTES':16,'YSYX_BRANCH_HISTORY_ENTRY_COUNT':16,'YSYX_BRANCH_TARGET_ENTRY_COUNT':16,'YSYX_BRANCH_TARGET_WAY_COUNT':2,'YSYX_RETURN_STACK_ENTRY_COUNT':4}
for kind,word in [('nop',0x13),('load',0x0009a303),('store',0x0089a023),('jal',0x0040006f)]:
 src=out/f'{kind}.S'; src.write_text((out/'program.S').read_text().replace('PATCH_WORD',hex(word)))
 subprocess.run(['riscv64-linux-gnu-as','-march=rv32i_zifencei','-mabi=ilp32','-o',str(out/f'{kind}.o'),str(src)],check=True)
 subprocess.run(['riscv64-linux-gnu-ld','-m','elf32lriscv','-Ttext=0x80000000','-o',str(out/f'{kind}.elf'),str(out/f'{kind}.o')],check=True)
 subprocess.run(['riscv64-linux-gnu-objcopy','-O','binary',str(out/f'{kind}.elf'),str(out/f'{kind}.bin')],check=True)
 data=(out/f'{kind}.bin').read_bytes(); (out/f'{kind}.hex').write_text(''.join(f'{int.from_bytes(data[i:i+4],"little"):08x}\n' for i in range(0,len(data),4)))
sources=[rtl/'common'/f for f in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_axi4_pkg.sv','riscv32_pkg.sv']]+sorted((rtl/'core').rglob('*.sv'))+[out/'fence_probe_tb.sv']
cmd=['verilator','--binary','--timing','--assert','-Wno-fatal','-j','2',*[f'+define+{k}'+('' if v is None else f'={v}') for k,v in macros.items()],'--top-module','fence_probe_tb','--Mdir',str(out/'obj'),*map(str,sources)]
(out/'manifest.json').write_text(json.dumps({'command':cmd,'source_hashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}},indent=2))
with (out/'build.log').open('w') as f:
 r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
if r.returncode: print((out/'build.log').read_text()[-5000:]); raise SystemExit(r.returncode)
for kind in ['nop','load','store','jal']:
 with (out/f'{kind}.log').open('w') as f:
  r=subprocess.run([str(out/'obj/Vfence_probe_tb'),f'+hex={out/kind}.hex'],stdout=f,stderr=subprocess.STDOUT)
 print(kind,r.returncode)
 print('\n'.join(l for l in (out/f'{kind}.log').read_text().splitlines() if any(s in l for s in ['FENCE','QUERY','FETCH','SUCCESSOR','RESULT','wrong-target','Error'])))
