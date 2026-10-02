#!/usr/bin/env python3
"""Confirm that the independent checker rejects deliberately incorrect BTB state."""
import argparse,hashlib,json,shutil,subprocess,sys
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];TOOL=Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,default=NPC/'result/branch-v3/btb-mutations');parser.add_argument('--only',nargs='+');args=parser.parse_args()
OUT=args.output;OUT.mkdir(exist_ok=False)
original=NPC/'vsrc/riscv32'
changes={
 'index':('index_value = pc[OFFSET_BITS+:SET_BITS];','index_value = pc[OFFSET_BITS + 1+:SET_BITS];'),
 'admission':('BTB_ADMISSION_POLICY == 1 ||',"1'b1 ||"),
 'rrip_insert':("reuse_array_q[training_set_index][training_way_index] <= 2'd2;","reuse_array_q[training_set_index][training_way_index] <= 2'd0;"),
 'invalidate':('end else if (invalidate_i) begin',"end else if (1'b0) begin"),
 'valid_invalidate':("end else if (invalidate_i) begin\n          for (int unsigned set_index = 0; set_index < SET_COUNT; set_index++) begin\n            entry_present_array_q[set_index]   <= '0;",
                      "end else if (1'b0) begin\n          for (int unsigned set_index = 0; set_index < SET_COUNT; set_index++) begin\n            entry_present_array_q[set_index]   <= '0;"),
}
if args.only:
 assert set(args.only)<=set(changes)
 changes={name:changes[name] for name in args.only}
records=[]
for name,(before,after) in changes.items():
 case=OUT/name;rtl=case/'rtl';(rtl/'common').mkdir(parents=True);(rtl/'core/frontend').mkdir(parents=True)
 for filename in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_axi4_pkg.sv','riscv32_pkg.sv']:shutil.copyfile(original/'common'/filename,rtl/'common'/filename)
 shutil.copyfile(original/'core/frontend/riscv32_compact_btb.sv',rtl/'core/frontend/riscv32_compact_btb.sv')
 source=original/'core/frontend/riscv32_btb.sv';text=source.read_text();assert before in text
 mutant=rtl/'core/frontend/riscv32_btb.sv';mutant.write_text(text.replace(before,after,1))
 command=[sys.executable,str(TOOL/'test_btb.py'),'--output',str(case/'test'),'--rtl',str(rtl)]
 with (case/'driver.log').open('x') as log:result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
 assert (case/'test/obj/Vbtb_test').exists(), 'Compilation failure is not a detected mutation'
 evidence=(case/'test/run.log').read_text();assert result.returncode!=0 and 'mismatch' in evidence,(name,evidence)
 records.append({'mutation':name,'before':before,'after':after,'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'mutant_sha256':hashlib.sha256(mutant.read_bytes()).hexdigest(),'command':command,'returncode':result.returncode,'detected':True,'evidence':evidence})
 (OUT/'results.json').write_text(json.dumps(records,indent=2)+'\n');print('PASS rejected mutation',name,flush=True)
