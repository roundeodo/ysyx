#!/usr/bin/env python3
"""Verify that the installed ABC actually receives the requested mapping delay."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

NPC = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--toolflow', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
source = out / 'mapping_probe.sv'
source.write_text("""module mapping_probe(
    input logic clk_i, rst_ni, enable_i,
    input logic [63:0] a_i, b_i,
    output logic [63:0] result_o
);
  logic [63:0] operand_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      operand_q <= '0;
      result_o <= '0;
    end else if (enable_i) begin
      operand_q <= a_i;
      result_o <= operand_q + b_i;
    end
  end
endmodule
""")
driver = NPC / 'scripts/synth_timing.tcl'
# Use the same quoted RTL/define argument as the Makefile qualification entry.
rtl_argument = '"-DNPC_MAPPING_PROBE=1 ' + str(source) + '"'
command = ['yosys', '-m', 'slang', '-p', 'tcl ' + ' '.join([
    str(driver), str(args.toolflow.resolve()), 'mapping_probe', 'nangate45',
    rtl_argument, str(out / 'mapping_probe.v'), '800'])]
with (out / 'run.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
text = (out / 'run.log').read_text()
targets = dict(re.findall(r'ABC:\s+\+\s+(map|upsize|dnsize)\b[^\n]*?-D\s+([0-9.]+)', text))
passed = result.returncode == 0 and all(
    operation in targets and abs(float(targets[operation]) - 1250.0) < 0.001
    for operation in ('map', 'upsize', 'dnsize'))
manifest = {'command': command, 'exit': result.returncode, 'passed': passed,
            'frequency_mhz': 800, 'expected_delay_ps': 1250.0, 'actual_delay_ps': targets,
            'driver_sha256': hashlib.sha256(driver.read_bytes()).hexdigest(),
            'scope': 'Mapping target propagation, not full-core timing qualification.'}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
if not passed:
    print(text[-4000:])
    raise SystemExit('Mapping delay target was not applied to every timing optimization')
print('PASS synthesis target: 1250 ps in map, upsize and dnsize')
