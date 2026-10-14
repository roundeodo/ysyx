import hashlib, json, os, shutil, subprocess, sys
from pathlib import Path
npc=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(npc/'scripts'))
from sta_report import timing
root=npc/'result/synthesis/btb-parallel/v3'
mapped=root/'sta/riscv32_core_reset_boundary-820MHz-buffered'
flow=npc/'result/sta/rv32-interrupt-20260906/toolflow'
module=json.loads((mapped/'buffered.json').read_text())['modules']['riscv32_core_reset_boundary']
result={'frequency_checks':{},'endpoint_scopes':{},'input_sha256':{name:hashlib.sha256((mapped/name).read_bytes()).hexdigest() for name in ('riscv32_core_reset_boundary.netlist.v','constraints.sdc')}}
for name,mhz in [('core700',700),('core715',715),('core720',720),('btb-training',700),('prediction-response',700)]:
    out=root/name;out.mkdir(exist_ok=True)
    netlist=out/'riscv32_core_reset_boundary.netlist.v';sdc=out/'constraints.sdc'
    shutil.copy2(mapped/netlist.name,netlist);shutil.copy2(mapped/sdc.name,sdc)
    script=flow/'scripts/sta.tcl'
    if name.startswith('core'):
        targets=None
    else:
        targets=[]
        for cell_name,cell in module['cells'].items():
            selected=('.u_btb.' in cell_name) if name=='btb-training' else any(fragment in cell_name for fragment in ['next_pc_predictor_prediction','next_pc_predictor_lookup_response_pc','next_pc_predictor_lookup_response_epoch','u_branch_predictor.response_'])
            if selected and cell['port_directions'].get('D')=='input':targets.append(cell_name+':D')
        assert targets,name
        (out/'targets.json').write_text(json.dumps(sorted(targets),indent=2)+'\n')
        text=script.read_text().replace('source "[file dirname [info script]]/common.tcl"',f'source "{flow}/scripts/common.tcl"').replace('report_timing -max_path 5','report_timing -max_path 5 -to {'+' '.join(sorted(targets))+'}')
        script=out/'scope.tcl';script.write_text(text)
    command=[str(flow/'bin/iEDA'),'-script',str(script),str(sdc),str(netlist),'riscv32_core_reset_boundary','nangate45']
    env={**os.environ,'CLK_FREQ_MHZ':str(mhz),'NPC_STA_NETLIST_FILE':str(netlist),'OMP_NUM_THREADS':'2','RUN_POWER_ANALYSIS':'0'}
    with (out/'sta.log').open('w') as log:subprocess.run(command,cwd=flow,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    assert 'The timing engine run success.' in (out/'sta.log').read_text()
    report=(out/'riscv32_core_reset_boundary.rpt').read_text()
    if targets is None:
        groups=timing(out);record={'mhz':mhz,'groups':groups,'passed':all(g['slack_ns']>=0 for g in groups.values()) and 'slack (VIOLATED)' not in report,'command':command}
        result['frequency_checks'][str(mhz)]=record
    else:
        rows=[]
        for line in report.splitlines():
            fields=[s.strip() for s in line.split('|')[1:-1]]
            if len(fields)==8 and fields[2] in ('max','min'):rows.append({'endpoint':fields[0],'type':fields[2],'slack_ns':float(fields[6]),'path_delay':fields[3]})
        assert rows,name
        record={'mhz':mhz,'target_pins':len(targets),'summary_rows':rows,'worst_setup_ns':min(r['slack_ns'] for r in rows if r['type']=='max'),'command':command}
        result['endpoint_scopes'][name]=record
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    (root/'core-probes.json').write_text(json.dumps(result,indent=2)+'\n')
    print(name,record.get('passed'),record.get('worst_setup_ns'),record.get('groups'),flush=True)
