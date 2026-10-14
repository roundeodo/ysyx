"""Paired standalone BTB mapping; never interpret this as whole-core Fmax."""
import hashlib, json, os, re, subprocess
from pathlib import Path
npc=Path(__file__).resolve().parents[3]
root=Path(__file__).resolve().parent
flow=npc/'result/sta/rv32-interrupt-20260906/toolflow'
sdc=root/'btb.sdc'
sdc.write_text((npc/'constr/riscv32_core_reset_boundary.sdc').read_text())
results=[]
for entries,ways,policy in [(16,2,0),(32,4,2),(32,8,2),(32,16,2)]:
    for variant in ('v2',):
        source=root/'parallel-v2.sv'
        sources=[npc/'vsrc/riscv32/common'/name for name in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_axi4_pkg.sv','riscv32_pkg.sv']]+[npc/'vsrc/riscv32/core/frontend/riscv32_compact_btb.sv',source]
        tag=f'{variant}-e{entries}-w{ways}-p{policy}'
        filelist=root/(tag+'.f');filelist.write_text('\n'.join(map(str,sources))+'\n')
        out=npc/'result/synthesis/btb-selection'/tag
        command=['python3',str(npc/'scripts/run_synthesis.py'),'--target','sta','--keep-artifacts','--output',str(out),'NPC_CONFIG=rv32-balanced','STA_DESIGN=riscv32_btb','STA_FREQUENCY_MHZ=820','STA_SYNTH_STRATEGY=AREA 3',f'STA_TOOL_DIR={flow}',f'STA_RTL_FILELIST={filelist}',f'STA_SDC_FILE={sdc}',f'NPC_BRANCH_TARGET_ENTRY_COUNT={entries}',f'NPC_BRANCH_TARGET_WAY_COUNT={ways}',f'NPC_BRANCH_TARGET_POLICY={policy}']
        config={'variant':variant,'entries':entries,'ways':ways,'policy':policy,'command':command,'source_hashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
        env={**os.environ,'NPC_HOME':str(npc),'OMP_NUM_THREADS':'2'}
        with (root/(tag+'.log')).open('w') as log:subprocess.run(command,cwd=npc.parent,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        mapped=out/'sta/riscv32_btb-820MHz'
        area=float(re.search(r'Chip area for module .*?:\s*([0-9.]+)',(mapped/'synth_stat.txt').read_text()).group(1))
        text=(mapped/'riscv32_btb.netlist.v').read_text()
        targets=[]
        # Mapped scalar sequential cells retain D pins in this library.
        for match in re.finditer(r'^\s*(\w+)\s+(\\?\S+)\s*\(\s*\n(.*?)^\s*\);',text,re.M|re.S):
            kind,name,body=match.groups()
            if '.D(' in body or '.D (' in body:targets.append(name.lstrip('\\')+':D')
        assert targets,(tag,'no training endpoints found')
        script=flow/'scripts/sta.tcl'
        scoped=root/(tag+'-training.tcl')
        scoped.write_text(script.read_text().replace('source "[file dirname [info script]]/common.tcl"',f'source "{flow}/scripts/common.tcl"').replace('report_timing -max_path 5','report_timing -max_path 5 -to {'+' '.join(targets)+'}'))
        # Same 700 MHz I/O assumptions and 820 MHz mapping for every paired geometry.
        env.update(CLK_FREQ_MHZ='700',NPC_STA_NETLIST_FILE=str(mapped/'riscv32_btb.netlist.v'),RUN_POWER_ANALYSIS='0')
        sta=[str(flow/'bin/iEDA'),'-script',str(scoped),str(sdc),str(mapped/'riscv32_btb.netlist.v'),'riscv32_btb','nangate45']
        with (root/(tag+'-training.log')).open('w') as log:subprocess.run(sta,cwd=flow,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        report=(mapped/'riscv32_btb.rpt').read_text()
        (root/(tag+'-training.rpt')).write_text(report)
        rows=[]
        for line in report.splitlines():
            fields=[s.strip() for s in line.split('|')[1:-1]]
            if len(fields)==8 and fields[2]=='max':rows.append({'endpoint':fields[0],'slack_ns':float(fields[6]),'path_delay':fields[3]})
        assert rows,tag
        config.update(area_um2=area,training_setup_ns=min(r['slack_ns'] for r in rows),training_rows=rows,training_command=sta,target_pins=len(targets),netlist_sha256=hashlib.sha256((mapped/'riscv32_btb.netlist.v').read_bytes()).hexdigest())
        results.append(config)
        (root/'selection-ppa-v2.json').write_text(json.dumps(results,indent=2)+'\n')
        print(tag,area,config['training_setup_ns'],flush=True)
