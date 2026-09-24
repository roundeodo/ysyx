#!/usr/bin/env python3
"""Measure query-to-resolution history age without driving any DUT signal."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import explore_frontend as experiment
from followup_branch import defines


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--config',default='G128')
    parser.add_argument('--resume',action='store_true')
    a=parser.parse_args();root=a.root.resolve();out=root/'history-observer'/a.config
    source=out/'source'
    out.mkdir(parents=True,exist_ok=a.resume)
    if not a.resume:
        shutil.copytree(root/'candidate-source/npc/vsrc',source/'npc/vsrc')
        shutil.copytree(root/'candidate-source/npc/tests/frontend_exploration',source/'npc/tests/frontend_exploration')
        path=source/'npc/tests/frontend_exploration/core_tb.sv';s=path.read_text()
        s=s.replace('    int query_cycle;','    int query_cycle;\n    int resolved_sequence;')
        anchor='  int response_query_cycle = 0;'
        s=s.replace(anchor,'''  int resolved_sequence_q = 0, response_resolved_sequence = 0;
      int history_age_zero = 0, history_age_one = 0, history_age_many = 0;
      int history_age_sum = 0, history_age_max = 0, history_bits_differ = 0;
      int history_error_zero = 0, history_error_one = 0, history_error_many = 0;
      int resolve_lead_sum = 0, resolve_lead_max = 0;
      // NBA sampling matches the pre-edge history read used by a same-edge query.
      always @(posedge clk) begin
        if (!rst_n) resolved_sequence_q <= 0;
        else if (dut.u_branch_predictor.u_bht.training_valid_i &&
                 !dut.u_branch_predictor.u_bht.invalidate_i)
          resolved_sequence_q <= resolved_sequence_q + 1;
      end
    '''+anchor)
        s=s.replace('      query_by_tag[dut.u_ifu.next_frontend_tag_q].query_cycle = response_query_cycle;',
                    '      query_by_tag[dut.u_ifu.next_frontend_tag_q].query_cycle = response_query_cycle;\n      query_by_tag[dut.u_ifu.next_frontend_tag_q].resolved_sequence = response_resolved_sequence;')
        s=s.replace('      response_query_cycle = cycle;', '      response_query_cycle = cycle;\n      response_resolved_sequence = resolved_sequence_q;')
        anchor='        branch_events++;'
        s=s.replace(anchor,anchor+'''
            if (dut.resolved_execute_result.uop.branch_ctrl.op == CF_BRANCH) begin
              int age, lead;
              bit prediction_error;
              if (result_record.pc != dut.resolved_execute_result.uop.pc)
                $fatal(1, "history observer pairing");
              age = resolved_sequence_q - result_record.resolved_sequence;
              lead = cycle - result_record.query_cycle;
              if (age < 0 || lead < 0) $fatal(1, "history observer age");
              prediction_error = dut.resolved_execute_result.redirect_valid;
              if (age == 0) begin history_age_zero++; history_error_zero += int'(prediction_error); end
              else if (age == 1) begin history_age_one++; history_error_one += int'(prediction_error); end
              else begin history_age_many++; history_error_many += int'(prediction_error); end
              history_age_sum += age;
              if (age > history_age_max) history_age_max = age;
              if (dut.resolved_execute_result.uop.prediction.direction.history !=
                  dut.u_branch_predictor.u_bht.history) history_bits_differ++;
              resolve_lead_sum += lead;
              if (lead > resolve_lead_max) resolve_lead_max = lead;
            end''')
        anchor='      $display("PASS proxy");'
        s=s.replace(anchor,'''      $display("HISTORY age_zero=%0d age_one=%0d age_many=%0d age_sum=%0d age_max=%0d bits_differ=%0d error_zero=%0d error_one=%0d error_many=%0d lead_sum=%0d lead_max=%0d",history_age_zero,history_age_one,history_age_many,history_age_sum,history_age_max,history_bits_differ,history_error_zero,history_error_one,history_error_many,resolve_lead_sum,resolve_lead_max);
    '''+anchor)
        path.write_text(s)
        experiment.TEST=source/'npc/tests/frontend_exploration'
        config=json.loads((root/'configurations.json').read_text())[a.config]
        experiment.build_rtl(out/'build',source/'npc/vsrc/riscv32',defines(config),host_opt=2)
    binary=out/'build/obj/Vexploration_core_tb'
    for name,digest in json.loads((out/'build/manifest.json').read_text())['sources'].items():
        assert experiment.sha(Path(name))==digest,name
    baseline=json.loads((root/'rtl/dev-common'/a.config/'results.json').read_text())
    records=[]
    for row in baseline['results']:
        command=[str(binary),*row['command'][1:]]
        command=[x for x in command if not x.startswith(('+trace=','+fetch_trace='))]
        log=out/(row['case']['name']+'.log')
        if not (a.resume and log.exists()):
            with log.open('w') as stream:subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,check=True)
        text=log.read_text();assert 'PASS proxy' in text
        values=dict(re.findall(r'(\w+)=([0-9a-f]+)',re.search(r'^RESULT .+$',text,re.M)[0]))
        values={k:int(v,16 if k in ['digest','checksum'] else 10) for k,v in values.items()}
        assert values==row['result'],row['case']['name']
        counters={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',re.search(r'^COUNTERS .+$',text,re.M)[0])}
        counters.update({k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',re.search(r'^DETAIL .+$',text,re.M)[0])})
        assert counters==row['counters'],row['case']['name']
        history={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',re.search(r'^HISTORY .+$',text,re.M)[0])}
        records.append({'case':row['case']['name'],'history':history,'command':command,'log_sha256':experiment.sha(log)})
        (out/'results.json').write_text(json.dumps({'scope':'passive diagnostic, query snapshot versus resolved history; correlation is not causal proof','binary_sha256':experiment.sha(binary),'results':records},indent=2)+'\n')
        print('HISTORY',row['case']['name'],history,flush=True)


if __name__=='__main__':main()
