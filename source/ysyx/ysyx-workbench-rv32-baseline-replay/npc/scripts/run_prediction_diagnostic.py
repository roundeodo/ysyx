#!/usr/bin/env python3
"""Match each oracle query to a frozen architectural PC sequence; compare equal windows."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from explore_frontend import sha


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    a=p.parse_args();root=a.root.resolve();out=root/'diagnostics';out.mkdir(exist_ok=False)
    baseline=json.loads((root/'rtl/dev-common/B0/results.json').read_text())
    binary=root/'builds/diagnostic/obj/Vexploration_core_tb';results=[]
    for row in baseline['results']:
        case=row['case'];name=case['name'];trace=root/'rtl/dev-common/B0'/(name+'.trace')
        records=[line.split(',') for line in trace.read_text().splitlines()]
        # start.S is a sequential SP setup and begin NOP; objdump is archived for inspection.
        disassembly=subprocess.check_output(['riscv64-linux-gnu-objdump','-d',str(root/'images'/name/'image.elf')],text=True)
        (out/(name+'.disassembly')).write_text(disassembly)
        assert records[0][0] == f'{case["begin_pc"]+4:08x}'
        pcs=list(range(0x80000000,case['begin_pc']+4,4))+[int(r[0],16) for r in records]
        for left,right in zip(records,records[1:]):assert int(left[2],16)==int(right[0],16)
        assert pcs[-1]==case['end_pc']
        # Extend through the result-store epilogue; simulation stops on the MMIO result.
        pcs+=list(range(case['end_pc']+4,case['end_pc']+36,4))
        oracle=out/(name+'.oracle');oracle.write_text(''.join(f'{pc:08x}\n' for pc in pcs))
        for mode in [0,1,2]:
            folder=out/f'mode{mode}';folder.mkdir(exist_ok=True)
            command=[str(binary),*row['command'][1:]]
            command=[x for x in command if not x.startswith(('+trace=','+fetch_trace='))]
            command += [f'+prediction_mode={mode}',f'+oracle={oracle}',f'+oracle_count={len(pcs)}']
            with (folder/(name+'.log')).open('w') as f:subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,check=True)
            text=(folder/(name+'.log')).read_text();assert 'PASS proxy' in text
            values=dict(re.findall(r'(\w+)=([0-9a-f]+)',re.search(r'^RESULT .+$',text,re.M)[0]))
            values={k:int(v,16 if k in ['digest','checksum'] else 10) for k,v in values.items()}
            counters={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',re.search(r'^COUNTERS .+$',text,re.M)[0])}
            for k in ['retired','all_retired','digest','checksum']:assert values[k]==row['result'][k],(name,mode,k)
            if mode==0:assert values==row['result']
            results.append({'name':name,'mode':mode,'command':command,'result':values,'counters':counters,
                            'time_ratio':values['cycles']/row['result']['cycles'],'oracle_sha256':sha(oracle)})
            (out/'results.json').write_text(json.dumps({'scope':'simulation diagnostics, not hardware results',
                'mhz':660,'binary_sha256':sha(binary),'results':results},indent=2)+'\n')
            print('DIAGNOSTIC',name,mode,values['cycles'],flush=True)


if __name__=='__main__':main()
