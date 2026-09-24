#!/usr/bin/env python3
"""Controlled correct/incorrect prediction pairs; full RTL measures the cycle cost."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import explore_frontend as experiment
from followup_branch import defines


def parse(text, label):
    line = re.search(r'^'+label+r' .+$', text, re.M)[0]
    return {k:int(v, 16 if k in ('digest','checksum') else 10)
            for k,v in re.findall(r'(\w+)=([0-9a-f]+)', line)}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--resume',action='store_true')
    a=p.parse_args(); root=a.root.resolve(); out=root/'penalty-audit'
    out.mkdir(exist_ok=a.resume)
    source=out/'source'; manifest=[]
    if not a.resume:
        shutil.copytree(root/'baseline/npc/vsrc',source/'npc/vsrc')
        shutil.copytree(root/'baseline/npc/tests/frontend_exploration',source/'npc/tests/frontend_exploration')
        path=source/'npc/vsrc/riscv32/core/frontend/riscv32_branch_predictor.sv'
        s=path.read_text(); anchor='  // 3. 预测选择：'
        assert s.count(anchor)==1
        pos=s.index(anchor)
        s=s[:pos]+'''  // Test-only intervention at one named PC; original response stage retained.
  int audit_mode = 0;
  logic [31:0] audit_pc, audit_target;
  initial begin
    void'($value$plusargs("audit_mode=%d", audit_mode));
    void'($value$plusargs("audit_pc=%h", audit_pc));
    void'($value$plusargs("audit_target=%h", audit_target));
  end
'''+s[pos:]
        anchor="    selected_prediction                  = '0;"
        assert s.count(anchor)==1
        s=s.replace(anchor,'''    if (audit_mode != 0 && lookup_request_pc_i == audit_pc) begin
      selected_taken = audit_mode == 1;
      selected_target_pc = audit_target;
    end
'''+anchor)
        path.write_text(s)
        path=source/'npc/tests/frontend_exploration/core_tb.sv';s=path.read_text()
        s=s.replace('  int cycle = 0,', '''  int audit_mode = 0, audit_start = 0, audit_fetch = 0, audit_redirects = 0;
  int audit_outstanding = 0, audit_last = 0, audit_ar_after = 0;
  logic [31:0] audit_pc, audit_target;
  initial begin
    void'($value$plusargs("audit_mode=%d", audit_mode));
    void'($value$plusargs("audit_pc=%h", audit_pc));
    void'($value$plusargs("audit_target=%h", audit_target));
  end
  int cycle = 0,''')
        s=s.replace('    cycle = cycle + 1;', '''    cycle = cycle + 1;
    if (dut.execute_redirect_resolution_event && dut.resolved_execute_result.uop.pc == audit_pc) begin
      audit_redirects++;
      audit_start = cycle;
      audit_outstanding = int'(u_arbiter.read_transaction_present_q);
    end
    if (audit_start && !audit_fetch && !dut.frontend_recovery_event &&
        dut.ifu_fetch_entry_valid && dut.ifu_fetch_entry_ready && dut.ifu_fetch_entry.pc == audit_target)
      audit_fetch = cycle;
    if (audit_start && !audit_fetch) begin
      if (memory_response.r_valid && memory_request.r_ready && memory_response.r.last) audit_last = cycle;
      if (memory_request.ar_valid && memory_response.ar_ready) audit_ar_after++;
    end''')
        s=s.replace('      $display("PASS proxy");', '''      if ((audit_mode == 1 && audit_redirects != 0) || (audit_mode == 2 && audit_redirects != 1))
        $fatal(1, "named-branch intervention mismatch");
      if (audit_redirects && audit_fetch <= audit_start) $fatal(1, "missing recovery latency");
      $display("AUDIT redirects=%0d start=%0d correct_fetch=%0d outstanding=%0d last=%0d ar_after=%0d",audit_redirects,audit_start,audit_fetch,audit_outstanding,audit_last,audit_ar_after);
      $display("PASS proxy");''')
        path.write_text(s)
        experiment.TEST=source/'npc/tests/frontend_exploration'
        experiment.build_rtl(out/'build',source/'npc/vsrc/riscv32',defines({'bht':16}),host_opt=2)
    binary=out/'build/obj/Vexploration_core_tb'
    for name, value in json.loads((out/'build/manifest.json').read_text())['sources'].items():
        assert experiment.sha(Path(name))==value,name
    # Warm one target and the probe line first. The wrong-path store must never retire.
    for layout, padding in [('warm',3),('cold_fallthrough',7)]:
        d=out/layout; d.mkdir(exist_ok=a.resume)
        assembly='''.section .text.start
.globl _start
.option norvc
_start:
  li a0, 0
  li t0, 0x10002000
  la ra, after_warm
  j target
after_warm:
  la ra, workload_end
  j prepare_probe
.balign 32
target:
  addi a0, a0, 1
  jr ra
.balign 32
prepare_probe:
'''+('  nop\n'*padding)+'''probe:
  beq zero, zero, target
  li a0, 99
  sw a0, 0(t0)
  j target
.balign 32
workload_end:
  nop
  sw a0, 0(t0)
1: j 1b
'''
        # Window begins before the initial probe-line fill, identically in both modes.
        (d/'probe.S').write_text(assembly)
        cmd=['riscv64-linux-gnu-gcc','-march=rv32i_zicsr_zifencei','-mabi=ilp32','-nostdlib','-static',
             '-Wl,--build-id=none','-T',experiment.NPC/'tests/frontend_exploration/link.ld',d/'probe.S','-o',d/'image.elf']
        experiment.run(cmd,d/'build.log')
        experiment.run(['riscv64-linux-gnu-objcopy','-O','binary',d/'image.elf',d/'image.bin'],d/'objcopy.log')
        data=(d/'image.bin').read_bytes()
        (d/'image.hex').write_text(''.join(f'{int.from_bytes(data[i:i+4],"little"):08x}\n' for i in range(0,len(data),4)))
        nm=subprocess.check_output(['riscv64-linux-gnu-nm',str(d/'image.elf')],text=True)
        addresses={x.split()[2]:int(x.split()[0],16) for x in nm.splitlines() if len(x.split())==3}
        for latency in (20,100,200):
            for stalls in (0,1):
                rows=[]
                for mode in (0,1,2):
                    label=f'{layout}-{latency}-{stalls}-{mode}'
                    cmd=[binary,f'+image={d/"image.hex"}',f'+begin_pc={addresses["after_warm"]:x}',
                         f'+end_pc={addresses["workload_end"]:x}','+expected=2','+cpu_mhz=720',
                         f'+latency_ns={latency}','+beat_ns=10','+memory_mode=physical',
                         f'+random_stalls={stalls}','+seed=97531',f'+audit_mode={mode}',
                         f'+audit_pc={addresses["probe"]:x}',f'+audit_target={addresses["target"]:x}',
                         f'+trace={out/(label+".trace")}']
                    experiment.run(cmd,out/(label+'.log'))
                    text=(out/(label+'.log')).read_text(); assert 'PASS proxy' in text
                    row={'mode':mode,'command':list(map(str,cmd)),'result':parse(text,'RESULT'),
                         'audit':parse(text,'AUDIT'),'counters':parse(text,'COUNTERS')}
                    rows.append(row)
                    # All modes execute the same instructions and retire the same effects.
                    assert all(row['result'][k]==rows[0]['result'][k] for k in ('retired','all_retired','digest','checksum'))
                    traces=[line.rsplit(',',1)[0] for line in (out/(label+'.trace')).read_text().splitlines()]
                    if mode==0: reference=traces
                    else: assert traces==reference
                # The unmodified frozen CPU must match diagnostic mode 0 exactly.
                original=[root/'builds/B0/obj/Vexploration_core_tb',
                          *[x for x in rows[0]['command'][1:] if not x.startswith(('+audit_','+trace='))]]
                original_log=out/f'unmodified-{layout}-{latency}-{stalls}.log'
                experiment.run(original,original_log)
                original_text=original_log.read_text()
                assert parse(original_text,'RESULT')==rows[0]['result']
                assert parse(original_text,'COUNTERS')==rows[0]['counters']
                manifest.append({'unmodified_mode0_parity':'passed','layout':layout,'latency_ns':latency,'stalls':stalls,
                                 'extra_cycles':rows[2]['result']['cycles']-rows[1]['result']['cycles'],
                                 'rows':rows,'image_sha256':experiment.sha(d/'image.bin')})
                (out/'results.json').write_text(json.dumps({'scope':'one named always-taken branch, correct versus deliberately wrong direction; diagnostic only, not a synthesizable predictor','results':manifest},indent=2)+'\n')
                print('PASS',layout,latency,stalls,'extra cycles',manifest[-1]['extra_cycles'],flush=True)

if __name__=='__main__':main()
