from pathlib import Path
import subprocess,json,hashlib,concurrent.futures
root=next(parent for parent in Path(__file__).resolve().parents if (parent/'ysyxSoC/perip/amba/axi4_delayer.v').is_file())
p=Path(__file__).resolve().parent
sources=[root/'ysyxSoC/perip/amba/axi4_delayer.v',root/'ysyxSoC/perip/sdram/core_sdram_axi4/sdram_axi_pmem.v',p/'write_read_probe.sv']
def run(ratio):
 out=p/str(ratio);out.mkdir(exist_ok=True)
 cmd=['verilator','--binary','--timing','--assert','-Wno-fatal','--top-module','write_read_probe',f'-GRATIO_SCALED={ratio}','--Mdir',str(out/'obj'),'-j','2',*map(str,sources)]
 with (out/'build.log').open('w') as log: subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
 rows=[]
 for late in [0,1]:
  r=subprocess.run([str(out/'obj/Vwrite_read_probe'),f'+LATE_READ={late}'],capture_output=True,text=True)
  (out/f'probe-{late}.log').write_text(r.stdout+r.stderr)
  r.check_returncode()
  row=json.loads(next(x for x in r.stdout.splitlines() if x.startswith('{')))
  rows.append(row);print(row,flush=True)
 return rows
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 rows=[r for group in pool.map(run,[1024,2048,4096,5939,7372]) for r in group]
(p/'probe-summary.json').write_text(json.dumps({'results':rows,'sources':{str(s):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}},indent=2)+'\n')
