#!/usr/bin/env python3
"""Complete the 10-case baseline if the software builder exposed an early manifest."""
import argparse,json,shutil,subprocess
from pathlib import Path
from types import SimpleNamespace
import explore_frontend as experiment
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);a=p.parse_args();root=a.root.resolve()
manifest=json.loads((root/'images/manifest.json').read_text());assert len(manifest['cases'])==22
existing=root/'rtl/dev-common/B0';old=json.loads((existing/'results.json').read_text());done={row['case']['name']:row for row in old['results']}
for case in manifest['cases']:
 if case['name'] in done:assert case['hashes']==done[case['name']]['case']['hashes']
missing=[case for case in manifest['cases'] if not case['held'] and case['name'] not in done]
if missing:
 images=root/'baseline-missing-images';images.mkdir()
 for case in missing:(images/case['name']).symlink_to(root/'images'/case['name'],target_is_directory=True)
 (images/'manifest.json').write_text(json.dumps(dict(manifest,cases=missing),indent=2)+'\n')
 out=root/'rtl/dev-completion/B0'
 experiment.simulate(SimpleNamespace(output=out,images=images,binary=root/'builds/B0/obj/Vexploration_core_tb',mhz=720,held_out=False,latency_ns=100,beat_ns=10,random_stalls=False,no_observer=False,no_trace=False,memory_mode='physical'))
 extra=json.loads((out/'results.json').read_text());assert extra['binary_sha256']==old['binary_sha256']
 for path in out.iterdir():
  if path.name=='results.json':continue
  assert not (existing/path.name).exists();shutil.copy2(path,existing/path.name)
 shutil.copy2(existing/'results.json',existing/'initial-six-results.json')
 old['results']+=extra['results'];old['completion_note']='Initial manifest had six development cases; added four after final 22-image manifest; identical hashes and simulator, no performance-driven case selection.'
 (existing/'results.json').write_text(json.dumps(old,indent=2)+'\n')
assert len(old['results'])==10
subprocess.run(['python3','npc/scripts/model_history.py','--root',str(root)],check=True)
