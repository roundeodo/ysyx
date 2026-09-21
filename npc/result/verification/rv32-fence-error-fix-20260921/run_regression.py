from pathlib import Path
import json,os,subprocess,re
out=Path(__file__).resolve().parent; root=out.parents[3]; npc=root/'npc'
env=dict(os.environ,NPC_HOME=str(npc),AM_HOME=str(root/'abstract-machine'),NEMU_HOME=str(root/'nemu'),NPC_TEST_BUILD_TIMEOUT='7200')
checks={
 'safety':['make','-C',str(npc),'git_commit=','NPC_CONFIG=rv32-baseline','test-precise-exception','test-timer-interrupt','test-dcache','test-fence-i-ctrl',f'CACHE_RECOVERY_OUTPUT={out}',f'EXCEPTION_TEST_OUTPUT={out}/exception',f'INTERRUPT_TEST_OUTPUT={out}/interrupt'],
 'lint':['make','-C',str(npc),'git_commit=','NPC_CONFIG=rv32-baseline','lint-npc','lint-soc'],
 'difftest':json.loads((npc/'result/performance/rv32-refine-20260921/difftest-command.json').read_text()),
 'rv64':['make','-C',str(npc),'git_commit=','NPC_CONFIG=rv64-sequential','test-dcache-miss','test-dcache-recovery','test-exu','test-fetch',f'CACHE_RECOVERY_OUTPUT={out}/rv64'],
 'single-word':['make','-C',str(npc),'git_commit=','NPC_CONFIG=rv32-baseline','NPC_DCACHE_LINE_BYTES=4','test-dcache-miss']}
results={}
for name,command in checks.items():
 with (out/f'{name}.log').open('w') as f:r=subprocess.run(command,cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT)
 results[name]={'command':command,'exit':r.returncode}
 (out/'regression.json').write_text(json.dumps(results,indent=2))
 print(name,r.returncode,flush=True)
 if r.returncode:raise SystemExit(r.returncode)
 if name=='difftest':
  s=re.sub(r'\x1b\[[0-9;]*m','',(out/f'{name}.log').read_text())
  assert len(re.findall(r'\[.*?\]\s+PASS',s))==35 and not re.search(r'\[.*?\]\s+FAIL',s)
