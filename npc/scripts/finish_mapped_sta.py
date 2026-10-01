#!/usr/bin/env python3
"""Buffer, audit and qualify a reset-boundary netlist without hiding failures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from repair_mapped_fanout import library_pins, quote
from refine_mapped_buffers import refine


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--netlist', type=Path, required=True)
    parser.add_argument('--toolflow', type=Path, required=True)
    parser.add_argument('--sdc', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--frequency', type=float, default=700)
    parser.add_argument('--fanout', type=int, default=0,
                        help='Optional project fanout cap; 0 uses electrical limits only')
    parser.add_argument('--headroom', type=float, default=1.0,
                        help='Fraction of the Liberty output-capacitance limit')
    parser.add_argument('--buffer-cell', default='BUF_X2')
    parser.add_argument('--resume-from', type=Path,
                        help='Copy a completed run and refine its failing paths; preserve the source')
    args = parser.parse_args()
    assert args.frequency > 0 and 0 < args.headroom <= 1
    assert args.fanout == 0 or args.fanout >= 2
    out = args.output.resolve()
    if out.exists():
        raise SystemExit('Preserve previous results; choose a new output directory: ' + str(out))
    out.parent.mkdir(parents=True, exist_ok=True)
    scripts = Path(__file__).resolve().parent
    flow = args.toolflow.resolve()
    library = flow / 'pdk/nangate45/lib/Nangate45_typ.lib'
    top = 'riscv_core_reset_boundary'
    env = dict(os.environ, OMP_NUM_THREADS='2', RUN_POWER_ANALYSIS='0',
               CLK_FREQ_MHZ=str(args.frequency),
               NPC_STA_NETLIST_FILE=str(out / (top + '.netlist.v')))
    steps = []

    def run(name, command, log_path, *, allow_failure=False):
        print('START', name, flush=True)
        with log_path.open('w') as log:
            result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        steps.append({'name': name, 'command': command, 'exit': result.returncode})
        if out.exists():
            (out / 'commands.json').write_text(json.dumps(steps, indent=2) + '\n')
        print('FINISH', name, result.returncode, flush=True)
        if result.returncode and not allow_failure:
            raise SystemExit(result.returncode)
        return result.returncode

    if args.resume_from:
        previous = args.resume_from.resolve()
        prior = json.loads((previous / 'provenance.json').read_text())
        repair = json.loads((previous / 'electrical-repair.json').read_text())
        assert prior['frequency_mhz'] == args.frequency
        assert prior['fanout_limit'] == args.fanout
        assert repair['capacitance_headroom_fraction'] == args.headroom
        assert repair['buffer_cell'] == args.buffer_cell
        assert prior['input_netlist_sha256'] == hashlib.sha256(args.netlist.read_bytes()).hexdigest()
        assert prior['library_sha256'] == hashlib.sha256(library.read_bytes()).hexdigest()
        assert repair['netlist_sha256'] == hashlib.sha256(
            (previous / (top + '.netlist.v')).read_bytes()).hexdigest()
        out.mkdir()
        for path in previous.iterdir():
            if path.is_file():
                shutil.copy2(path, out / path.name)
    else:
        run('electrical repair', ['python3', str(scripts / 'repair_mapped_fanout.py'),
            '--netlist', str(args.netlist.resolve()), '--liberty', str(library),
            '--output-dir', str(out), '--fanout', str(args.fanout),
            '--headroom', str(args.headroom), '--buffer-cell', args.buffer_cell],
            out.parent / (out.name + '-repair.log'))
    copied = out / 'flow-scripts'
    copied.mkdir()
    for name in ['repair_mapped_fanout.py', 'check_reset_netlist.py', 'check_sta_acceptance.py',
                 'finish_mapped_sta.py', 'refine_mapped_buffers.py', 'clock_buffer_constraints.py']:
        shutil.copy2(scripts / name, copied / name)
    def write_constraints():
        shutil.copy2(args.sdc, out / 'constraints.sdc')
        run('clock coverage constraints', ['python3', str(copied / 'clock_buffer_constraints.py'),
            '--netlist-json', str(out / 'buffered.json'),
            '--output', str(out / 'clock-buffers.sdc')], out / 'clock-coverage-constraints.log')
        with (out / 'constraints.sdc').open('a') as stream:
            stream.write('\n' + (out / 'clock-buffers.sdc').read_text())
        # A defined output budget makes register/logic-to-output checks reproducible.
        with (out / 'constraints.sdc').open('a') as stream:
            stream.write('''
    # iEDA accepts individual get_ports objects for set_load, not all_outputs.
    # The single-DFF probe verifies 0.01 means 0.01 pF = 10 fF in this tool.
    set output_load_file [open $::env(NPC_STA_NETLIST_FILE) r]
    set output_load_text [read $output_load_file]
    close $output_load_file
    set output_load_count 0
    foreach line [split $output_load_text "\\n"] {
      if {[regexp {^\\s*output\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*;} $line match port_name]} {
        set_load 0.01 [get_ports $port_name]
        incr output_load_count
      }
    }
    if {$output_load_count == 0} {error "No scalar output load applied"}
    puts "Output load budget: $output_load_count ports, 0.01 pF each"
    ''')
    write_constraints()

    provenance = {'frequency_mhz': args.frequency, 'top': top, 'fanout_limit': args.fanout,
                  'capacitance_headroom_fraction': args.headroom, 'buffer_cell': args.buffer_cell,
                  'input_netlist_sha256': hashlib.sha256(args.netlist.read_bytes()).hexdigest(),
                  'library_sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
                  'sdc_sha256': hashlib.sha256((out / 'constraints.sdc').read_bytes()).hexdigest(),
                  'script_sha256': {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
                                    for f in copied.iterdir()}}
    reuse_prior_sta = False
    if args.resume_from:
        prior_sdc = (args.resume_from / 'constraints.sdc').read_bytes()
        reuse_prior_sta = prior_sdc == (out / 'constraints.sdc').read_bytes()
        provenance['resumed_from'] = str(args.resume_from.resolve())
        provenance['prior_sta_reusable'] = reuse_prior_sta
    (out / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')

    for attempt in range(4):
        run('reset connectivity', ['python3', str(copied / 'check_reset_netlist.py'),
            str(out / 'buffered.json'), '--output', str(out / 'reset-connectivity.json')],
            out / 'reset-audit.log')
        # Resume only reuses the reports whose exact netlist/library/SDC were checked above.
        if attempt or not reuse_prior_sta:
            run('STA', [str(flow / 'bin/iEDA'), '-script', str(flow / 'scripts/sta.tcl'),
                str(out / 'constraints.sdc'), str(out / (top + '.netlist.v')), top, 'nangate45'],
                out / 'sta.log')
        code = run('complete acceptance', ['python3', str(copied / 'check_sta_acceptance.py'),
                   str(out)], out / 'acceptance.log', allow_failure=True)
        if not code:
            print('QUALIFIED', out, flush=True)
            return
        acceptance = json.loads((out / 'acceptance.json').read_text())
        timing = acceptance['timing']['groups']
        # Bypassing buffers can shorten min paths. Never use it to repair a
        # hold/removal failure; rerun every min and electrical check afterward.
        if (attempt == 3 or not acceptance['reset_and_connection_audits_passed'] or
                any(timing[key]['slack_ns'] < 0 for key in ['data_min', 'gating_min']) or
                all(timing[key]['slack_ns'] >= 0 for key in ['data_max', 'gating_max'])):
            raise SystemExit(code)
        design = json.loads((out / 'buffered.json').read_text())
        original = json.loads((out / 'before.json').read_text())['modules'][top]
        summary = refine(original, design['modules'][top], library_pins(library),
                         (out / (top + '.rpt')).read_text(), fanout=args.fanout, headroom=args.headroom)
        if not summary['changes']:
            raise SystemExit('No legal buffer refinement; full STA still fails')
        archive = out / 'attempts' / str(attempt)
        archive.mkdir(parents=True)
        for path in out.iterdir():
            if path.is_file():
                shutil.copy2(path, archive / path.name)
        (out / 'buffer-refinement.json').write_text(json.dumps(summary, indent=2) + '\n')
        (out / 'buffered.json').write_text(json.dumps(design))
        # The JSON graphs are large; do not retain them while another tool loads the netlist.
        del design, original
        netlist = out / (top + '.netlist.v')
        write_script = out / 'refine.ys'
        write_script.write_text(
            f'read_json {quote(out / "buffered.json")}\nhierarchy -top {top}\n'
            f'select {top}\ntee -o {quote(out / "synth_check.txt")} check -mapped\n'
            f'tee -o {quote(out / "synth_stat.txt")} stat -liberty {quote(library)}\n'
            f'write_verilog -noattr -noexpr -nohex -nodec {quote(netlist)}\n')
        run('critical buffer refinement', ['yosys', '-Q', '-T', '-s', str(write_script)],
            out / 'refine.log')
        repair = json.loads((out / 'electrical-repair.json').read_text())
        repair.update({key: summary[key] for key in ['structural_equivalence',
                      'static_load_audit', 'maximum_cell_output_fanout']})
        repair['netlist_sha256'] = hashlib.sha256(netlist.read_bytes()).hexdigest()
        repair['timing_refinement'] = 'buffer-refinement.json'
        (out / 'electrical-repair.json').write_text(json.dumps(repair, indent=2) + '\n')
        # Buffer refinement can change clock targets. Regenerate from the new graph.
        write_constraints()
        provenance['sdc_sha256'] = hashlib.sha256((out / 'constraints.sdc').read_bytes()).hexdigest()
        (out / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')


if __name__ == '__main__':
    main()
