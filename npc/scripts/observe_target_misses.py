#!/usr/bin/env python3
"""Classify actual BTB query misses using a passive training-time LRU shadow."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import explore_frontend as experiment
from followup_branch import defines


DECLARATIONS = '''
  int response_miss_class = 0;
  int class_errors[4] = '{default:0};
  int untrained_then_trained = 0;
  bit trained_pc[logic [31:0]];
  logic [31:0] shadow_pc[BRANCH_TARGET_ENTRY_COUNT];
  bit shadow_present[BRANCH_TARGET_ENTRY_COUNT] = '{default:0};
'''
QUERY = '''
      response_miss_class = 0;
      if (!dut.u_branch_predictor.target_present) begin
        bit shadow_hit;
        shadow_hit = 0;
        for (int entry = 0; entry < BRANCH_TARGET_ENTRY_COUNT; entry++)
          if (shadow_present[entry] && shadow_pc[entry] == dut.u_branch_predictor.u_btb.lookup_pc_i)
            shadow_hit = 1;
        if (!trained_pc.exists(dut.u_branch_predictor.u_btb.lookup_pc_i)) response_miss_class = 1;
        else if (shadow_hit) response_miss_class = 2;
        else response_miss_class = 3;
      end
'''
CLASSIFY = '''
          if (!result_record.target_present) begin
            if (result_record.miss_class < 1 || result_record.miss_class > 3)
              $fatal(1, "target classifier query identity");
            class_errors[result_record.miss_class]++;
            if (result_record.miss_class == 1 && trained_pc.exists(result_record.pc))
              untrained_then_trained++;
          end
'''
TRAIN = '''
    // Update after query/resolve sampling: same-edge lookup reads pre-edge table.
    if (dut.u_branch_predictor.u_btb.invalidate_i) begin
      trained_pc.delete();
      foreach (shadow_present[entry]) shadow_present[entry] = 0;
    end else if (dut.u_branch_predictor.u_btb.training_valid_i) begin
      int old_position;
      old_position = BRANCH_TARGET_ENTRY_COUNT - 1;
      for (int entry = 0; entry < BRANCH_TARGET_ENTRY_COUNT; entry++)
        if (shadow_present[entry] && shadow_pc[entry] == dut.u_branch_predictor.u_btb.training_pc_i)
          old_position = entry;
      for (int entry = BRANCH_TARGET_ENTRY_COUNT - 1; entry > 0; entry--)
        if (entry <= old_position) begin
          shadow_pc[entry] = shadow_pc[entry-1];
          shadow_present[entry] = shadow_present[entry-1];
        end
      shadow_pc[0] = dut.u_branch_predictor.u_btb.training_pc_i;
      shadow_present[0] = 1;
      trained_pc[dut.u_branch_predictor.u_btb.training_pc_i] = 1;
    end
'''
REPORT = '''
      if (class_errors[1] + class_errors[2] + class_errors[3] != btb_miss_errors)
        $fatal(1, "target miss classification accounting");
      $display("BTBCLASS untrained=%0d mapping_or_replacement=%0d capacity=%0d untrained_then_trained=%0d",
               class_errors[1],class_errors[2],class_errors[3],untrained_then_trained);
'''


def values(text, prefix, hexadecimal=()):
    line = re.search(r'^' + prefix + r' .+$', text, re.M)[0]
    return {key: int(value, 16 if key in hexadecimal else 10)
            for key, value in re.findall(r'(\w+)=([0-9a-f]+)', line)}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--resume', action='store_true')
    a = p.parse_args()
    root = a.root.resolve()
    out = root / 'target-observer'
    out.mkdir(exist_ok=a.resume)
    source = out / 'source/npc'
    if not a.resume:
        shutil.copytree(root / 'baseline/npc/vsrc', source / 'vsrc')
        shutil.copytree(root / 'baseline/npc/tests/frontend_exploration', source / 'tests/frontend_exploration')
        path = source / 'tests/frontend_exploration/core_tb.sv'
        text = path.read_text()
        text = text.replace('    int query_cycle;', '    int query_cycle;\n    int miss_class;')
        text = text.replace('  int response_query_cycle = 0;', DECLARATIONS + '  int response_query_cycle = 0;')
        anchor = '      query_by_tag[dut.u_ifu.next_frontend_tag_q].query_cycle = response_query_cycle;'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '\n      query_by_tag[dut.u_ifu.next_frontend_tag_q].miss_class = response_miss_class;')
        text = text.replace('      response_query_cycle = cycle;', '      response_query_cycle = cycle;' + QUERY)
        text = text.replace('          if (!result_record.target_present) btb_miss_errors++;', CLASSIFY + '          if (!result_record.target_present) btb_miss_errors++;')
        text = text.replace('    // Half-open window', TRAIN + '    // Half-open window')
        text = text.replace('      $display("PASS proxy");', REPORT + '      $display("PASS proxy");')
        path.write_text(text)
        experiment.TEST = source / 'tests/frontend_exploration'
        experiment.build_rtl(out / 'build', source / 'vsrc/riscv32', defines({'bht': 16}), host_opt=2)
    binary = out / 'build/obj/Vexploration_core_tb'
    for name, expected in json.loads((out / 'build/manifest.json').read_text())['sources'].items():
        assert experiment.sha(Path(name)) == expected, name
    baseline = json.loads(a.reference.read_text())
    rows = []
    for reference in baseline['results']:
        command = [str(binary), *reference['command'][1:]]
        command = [word for word in command if not word.startswith(('+trace=', '+fetch_trace='))]
        log = out / (reference['case']['name'] + '.log')
        if not (a.resume and log.exists()):
            with log.open('w') as stream:
                subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True)
        text = log.read_text()
        assert 'PASS proxy' in text
        assert values(text, 'RESULT', ('digest', 'checksum')) == reference['result']
        counters = values(text, 'COUNTERS') | values(text, 'DETAIL')
        assert counters == reference['counters'], reference['case']['name']
        classification = values(text, 'BTBCLASS')
        rows.append({'case': reference['case']['name'], 'family': reference['case']['kind'],
                     'classification': classification, 'command': command, 'log_sha256': experiment.sha(log)})
        (out / 'results.json').write_text(json.dumps({
            'scope': 'actual pre-edge query paired through existing handoffs; capacity/mapping labels relative to same-capacity training-updated fully-associative LRU; not pure conflict attribution',
            'observer_preserved_all_results_and_counters': True, 'binary_sha256': experiment.sha(binary),
            'reference_sha256': experiment.sha(a.reference), 'results': rows}, indent=2) + '\n')
        print('CLASSIFY', reference['case']['name'], classification, flush=True)


if __name__ == '__main__':
    main()
