from pathlib import Path
import subprocess,resource,json
out=Path(__file__).resolve().parent
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
results=[]
for label,opts in [('clean-error-assertions',[]),('clean-error-hardware',['+verilator+noassert'])]:
 cmd=[str(out/'obj/Vfence_probe_tb'),f'+hex={out}/nop.hex','+clean_fault=1',*opts]
 with (out/f'{label}.log').open('w') as f:
  r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 results.append({'label':label,'command':cmd,'exit':r.returncode})
 print(label,r.returncode)
(out/'clean-error-runs.json').write_text(json.dumps(results,indent=2))
