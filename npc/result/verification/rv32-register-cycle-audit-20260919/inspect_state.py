#!/usr/bin/env python3
"""Record source identity and count selected registers in the existing mapped netlist."""
import collections
import hashlib
import json
from pathlib import Path
import re
import subprocess

OUTPUT = Path(__file__).resolve().parent
ROOT = OUTPUT.parents[3]
RTL = ROOT / 'npc/vsrc/riscv32'
PPA = ROOT / 'npc/result/performance/rv32-precise-exception-20260919'
NETLIST = PPA / 'sta/riscv32_core_reset_boundary-820MHz-buffered/buffered.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


sources = [Path(line.replace('${NPC_HOME}', str(ROOT / 'npc')))
           for line in (RTL / 'filelist/filelist_sta.f').read_text().splitlines()
           if line.startswith('${NPC_HOME}')]
previous_hashes = json.loads((PPA / 'source-hashes.json').read_text())
inventory = []
for path in sources:
    name = str(path.relative_to(ROOT))
    assert digest(path) == previous_hashes[name], name
    inventory.append({'path': name, 'sha256': digest(path),
                      'kind': 'package' if path.parent.name == 'common' else 'module'})

cells = json.loads(NETLIST.read_text())['modules']['riscv32_core_reset_boundary']['cells']
patterns = {
    'ifu_prediction_table': r'u_core\.u_ifu\.prediction_by_frontend_tag_array_q\[\d+\]_\d+__reg_p',
    'redirect_payloads': r'u_core\.u_redirect_stage\.redirect_req_array_q_\d+__reg_p',
    'id_ex_skid_payload': r'u_core\.u_id_ex_reg\.skid_execute_packet_q_\d+__reg_p',
    'predictor_training_payload': r'u_core\.u_branch_predictor\.training_q_\d+__reg_p',
}
groups = {}
for label, pattern in patterns.items():
    selected = {name: cell['type'] for name, cell in cells.items()
                if cell['type'].startswith('DFF') and re.fullmatch(pattern, name)}
    groups[label] = {'count': len(selected), 'cells': selected}

# Packed dcache_writeback_req_t: transaction_id[3:0], line_data[131:4], address above.
# Mapping aliases the miss-unit source buffer to the AXI adapter's input signal name.
for field in ('writeback_req_i', 'writeback_context_q'):
    pattern = (r'u_core\.u_data_mem\.gen_dcache\.u_dcache\.u_dcache_axi\.' +
               field + r'_(\d+)__reg_p')
    selected = {}
    for name, cell in cells.items():
        match = re.fullmatch(pattern, name)
        if match and cell['type'].startswith('DFF') and 4 <= int(match[1]) < 132:
            selected[name] = cell['type']
    groups[field + '_line_payload'] = {'count': len(selected), 'cells': selected}

result = {
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'configuration': 'rv32-baseline', 'scope': 'structural review, no RTL changes or new PPA run',
    'mapped_json': str(NETLIST.relative_to(ROOT)), 'mapped_json_sha256': digest(NETLIST),
    'source_inventory': inventory, 'register_groups': groups,
    'other_files': [str(p.relative_to(ROOT)) for p in sorted(RTL.rglob('*'))
                    if p.is_file() and p not in sources],
}
(OUTPUT / 'state-inventory.json').write_text(json.dumps(result, indent=2) + '\n')
print('Sources:', dict(collections.Counter(item['kind'] for item in inventory)))
for name, group in groups.items():
    print(f'{name}: {group["count"]} mapped flip-flops')
