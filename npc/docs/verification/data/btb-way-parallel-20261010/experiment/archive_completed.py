"""Retain measured evidence before removing this task's completed scratch only."""
import gzip, hashlib, json, shutil
from pathlib import Path
npc=Path(__file__).resolve().parents[3]
root=Path(__file__).resolve().parent
dest=npc/'docs/verification/data/btb-way-parallel-20261010';dest.mkdir(parents=True,exist_ok=True)
index=[]
def retain(p,q,compress=False):
    q.parent.mkdir(parents=True,exist_ok=True)
    if compress:
        with p.open('rb') as src,gzip.open(str(q)+'.gz','wb') as dst:shutil.copyfileobj(src,dst)
        final=Path(str(q)+'.gz')
    else:shutil.copy2(p,q);final=q
    index.append({'source':str(p.relative_to(npc)),'retained':str(final.relative_to(dest)),'source_sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
for case in ['unit','unit-v2','unit-v2-fixed','frontend']:
    source=root/case
    for p in source.rglob('*'):
        if not p.is_file() or 'obj' in p.relative_to(source).parts:continue
        if p.suffix in ['.json','.sv','.cpp','.log']:retain(p,dest/'tests'/case/p.relative_to(source),p.suffix in ['.sv','.cpp','.log'])
    for p in source.rglob('obj'):
        if p.is_dir():shutil.rmtree(p)
for variant in ['current','v2']:
    source=npc/'result/synthesis/btb-parallel'/variant
    for p in source.rglob('*'):
        if not p.is_file():continue
        rel=p.relative_to(source)
        if p.name in ['buffered.json'] or p.is_symlink():continue
        if p.suffix in ['.rpt','.sdc','.tcl'] or p.name in ['configuration.json','core-probes.json','reset-tree.json','reset-connectivity.json','result.json','targets.json','synth_stat.txt','synth_check.txt']:
            retain(p,dest/'core'/variant/rel,p.suffix=='.rpt')
        elif p.name=='riscv32_core_reset_boundary.netlist.v' and p.parent.name.endswith('buffered'):
            retain(p,dest/'core'/variant/'mapped-netlist.v',True)
    for p in [source/'sta',*[p for p in source.iterdir() if p.is_dir() and (p.name.startswith('core') or p.name in ['btb-training','prediction-response'])]]:
        if p.is_dir():shutil.rmtree(p)
for source in (npc/'result/synthesis/btb-selection').iterdir():
    for p in source.rglob('*'):
        if not p.is_file() or p.is_symlink():continue
        rel=p.relative_to(source)
        if p.suffix=='.rpt' or p.name in ['configuration.json','synth_stat.txt','synth_check.txt']:
            retain(p,dest/'selection'/source.name/rel,p.suffix=='.rpt')
        elif p.name=='riscv32_btb.netlist.v':retain(p,dest/'selection'/source.name/'mapped-netlist.v',True)
    if (source/'sta').is_dir():shutil.rmtree(source/'sta')
for p in root.iterdir():
    if p.is_file() and p.suffix in ['.sv','.f','.py','.sdc','.json','.rpt','.log']:
        retain(p,dest/'experiment'/p.name,p.suffix in ['.rpt','.log'])
retain(root/'reference/riscv32_btb.sv',dest/'experiment/before.sv')
(dest/'archive-index.json').write_text(json.dumps(index,indent=2)+'\n')
print('Archived files:',len(index),'bytes:',sum(p.stat().st_size for p in dest.rglob('*') if p.is_file()))
