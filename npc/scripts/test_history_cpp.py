#!/usr/bin/env python3
"""Cross-check all screening configurations against the independent Python model."""
import sys,subprocess,argparse,json,hashlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from model_history import read_trace,configurations
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
root=p.parse_args().root.resolve();trace=root/'rtl/dev-common/B0/json_bpe-dev-331.trace';sample=root/'model-parity.trace'
with trace.open() as source,sample.open('w') as out:
 for i,line in enumerate(source):
  if i==8000:break
  out.write(line)
records,instructions=read_trace(sample)
rows={r.split(',')[0]:list(map(int,r.split(',')[1:])) for r in subprocess.check_output([str(root/'direction_model'),str(sample)],text=True).splitlines()}
for name,factory in configurations().items():
 model=factory();errors=0;false_taken=0
 for pc,_,taken,target,_,_ in records:
  pred=model.predict(pc,target);errors+=pred!=taken;false_taken+=pred and not taken;model.update(pc,target,taken)
 assert rows[name]==[model.state_bits(),errors,false_taken,len(records),instructions],(name,rows[name],errors)
print('PASS Python/C++ agreement',len(rows),'configurations',instructions,'instructions')
(root/'model-parity.json').write_text(json.dumps({'status':'passed','configurations':len(rows),'instructions':instructions,'trace_sha256':hashlib.sha256(sample.read_bytes()).hexdigest()},indent=2)+'\n')
