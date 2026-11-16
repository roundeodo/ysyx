#!/usr/bin/env python3
"""Independent full-PC C++ oracle against RTL query and every valid state entry."""
import argparse,hashlib,json,subprocess,resource
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];TOOL=Path(__file__).resolve().parent
parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,default=NPC/'result/branch-v3/btb-unit-expanded');parser.add_argument('--rtl',type=Path,default=NPC/'vsrc/riscv32');args=parser.parse_args();OUT=args.output.resolve()
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
OUT.mkdir(exist_ok=False)
configs=[(16,w,i,p,a) for w in (2,4) for i in (0,1,2) for p in (0,2,3) for a in (1,2) if p!=3 or w==2]
configs += [(n,2,0,0,0) for n in (16,32,64,128)]
configs += [(16,2,0,p,0) for p in (1,2,3)]
configs += [(32,4,1,2,2),(64,4,2,2,2)]
configs += [(16,w,i,4,a) for w in (2,4) for i in (0,1,2) for a in (1,2)]
configs += [(32,4,2,4,2),(64,4,2,4,2)]
assert len(configs) <= 64
header=f'''module btb_test(input logic clk_i,rst_ni,valid_i,taken_i,invalidate_i,
input logic [31:0] lookup_i,pc_i,target_i,input logic [1:0] kind_i,
output logic [{len(configs)-1}:0] present_o,
output logic [31:0] target_o [{len(configs)}],output logic [1:0] kind_o [{len(configs)}],
output logic [63:0] state_o [{len(configs)*128}],
output logic [1:0] reuse_o [{len(configs)*128}],
output logic reused_o [{len(configs)*128}],
output logic [1:0] signature_o [{len(configs)*16}],
output logic [1:0] next_o [{len(configs)*64}]);
import riscv32_pkg::*;
'''
for n,(entries,ways,index,policy,admission) in enumerate(configs):
    bits=(entries//ways).bit_length()-1
    header+=f'''riscv32_btb #(.BTB_ENTRY_COUNT({entries}),.BTB_WAY_COUNT({ways}),.BTB_INDEX_POLICY({index}),.BTB_POLICY({policy}),.BTB_ADMISSION_POLICY({admission})) u{n} (
.clk_i,.rst_ni,.lookup_pc_i(lookup_i),.lookup_target_present_o(present_o[{n}]),.lookup_target_pc_o(target_o[{n}]),.lookup_target_kind_o(kind_o[{n}]),
.training_pc_i(pc_i),.training_target_pc_i(target_i),.training_kind_i(branch_target_kind_e'(kind_i)),.training_valid_i(valid_i),.training_taken_i(taken_i),.invalidate_i);
'''
    for j in range(128):
        if j<entries:
            path=f'u{n}.g_full_target';s,w=divmod(j,ways)
            header+=f"assign state_o[{n*128+j}] = {{ {path}.entry_present_array_q[{s}][{w}], {path}.entry_array_q[{s}][{w}].kind, {bits-1}'b0, {path}.entry_array_q[{s}][{w}].tag, {path}.entry_array_q[{s}][{w}].target_pc }};\n"
            header+=f"assign reuse_o[{n*128+j}] = "+(f'{path}.reuse_array_q[{s}][{w}]' if policy in (2,4) else "2'b0")+';\n'
            header+=f"assign reused_o[{n*128+j}] = "+(f'{path}.g_reuse.g_signature.reused_array_q[{s}][{w}]' if policy==4 else "1'b0")+';\n'
        else:header+=f"assign state_o[{n*128+j}]=0; assign reuse_o[{n*128+j}]=0; assign reused_o[{n*128+j}]=0;\n"
    for j in range(16):
        header+=f"assign signature_o[{n*16+j}] = "+(f'u{n}.g_full_target.g_reuse.g_signature.signature_counter_array_q[{j}]' if policy==4 else "2'b0")+';\n'
    for s in range(64):
        header+=f"assign next_o[{n*64+s}]="+(f'u{n}.g_full_target.replacement_way_array_q[{s}]' if s<entries//ways else "2'b0")+';\n'
header+='endmodule\n';(OUT/'test.sv').write_text(header)
cpp=r'''
#include "Vbtb_test.h"
#include "btb_model.h"
#include <random>
#include <iostream>
#include <stdexcept>
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);Vbtb_test dut;
 std::vector<BtbConfig> configs=CONFIGURATIONS;
 std::vector<BtbModel> models;for(auto c:configs) models.emplace_back(c);
 std::mt19937 rng(0x20261001);uint64_t queries=0,states=0;
 auto check=[&]() {
  for(unsigned n=0;n<models.size();++n) {
   auto &m=models[n];auto *e=m.lookup(dut.lookup_i);
   bool present=(dut.present_o>>n)&1;
   if(present!=bool(e)||(e&&(dut.target_o[n]!=e->target||dut.kind_o[n]!=e->kind))) throw std::runtime_error("query mismatch config "+std::to_string(n));
   ++queries;
   unsigned bits=0;while((1u<<bits)<m.rows.size()) ++bits;
   if(m.config.policy==4) for(unsigned j=0;j<16;++j)
    if(dut.signature_o[n*16+j]!=m.signatures[j]) throw std::runtime_error("signature counter mismatch config "+std::to_string(n));
   for(unsigned s=0;s<m.rows.size();++s) {
    if(dut.next_o[n*64+s]!=m.next[s]) throw std::runtime_error("replacement pointer mismatch");
    for(unsigned w=0;w<m.config.ways;++w) {
     const auto &entry=m.rows[s][w];auto observed=dut.state_o[n*128+s*m.config.ways+w];
     uint64_t expected=(uint64_t(entry.present)<<63)|(uint64_t(entry.kind)<<61)|(uint64_t(entry.pc>>(2+bits))<<32)|entry.target;
     if(bool(observed>>63)!=entry.present || (entry.present&&observed!=expected)) throw std::runtime_error("table state mismatch config "+std::to_string(n));
     if((m.config.policy==2||m.config.policy==4) && dut.reuse_o[n*128+s*m.config.ways+w]!=entry.reuse) throw std::runtime_error("RRPV mismatch config "+std::to_string(n));
     if(m.config.policy==4 && dut.reused_o[n*128+s*m.config.ways+w]!=entry.reused) throw std::runtime_error("reuse outcome mismatch config "+std::to_string(n));
     ++states;
    }
   }
  }
 };
 dut.clk_i=0;dut.rst_ni=0;dut.valid_i=0;dut.invalidate_i=0;dut.eval();dut.clk_i=1;dut.eval();dut.rst_ni=1;
 for(unsigned step=0;step<12000;++step) {
  dut.clk_i=0;
  // Directed conflicts, high-PC tag collisions, repeated targets and randomized full addresses.
  dut.pc_i=step<2000 ? (0x80000000u+((step/3)%80)*64+((step/240)%4)*4) : ((rng()%5)?0x80000000u+(rng()%256)*4:rng()&~3u);
  dut.lookup_i=(step%3==0)?dut.pc_i:((rng()%6)?0x80000000u+(rng()%256)*4:rng()&~3u);
  dut.target_i=rng()&~3u;dut.kind_i=rng()%4;dut.taken_i=rng()%2;
  dut.valid_i=(step%9!=0);dut.invalidate_i=step%257==256;
  dut.eval();check();
  for(auto &m:models) {if(dut.invalidate_i)m.clear();else if(dut.valid_i)m.train(dut.pc_i,dut.target_i,dut.kind_i,dut.taken_i);}
  dut.clk_i=1;dut.eval();check();
  // Query after training without waiting another cycle.
  dut.lookup_i=dut.pc_i;dut.eval();check();
 }
 std::cout<<"PASS BTB configs="<<models.size()<<" queries="<<queries<<" state_entries="<<states<<" seed=0x20261001\n";
}
'''.replace('CONFIGURATIONS','{'+','.join('{'+','.join(map(str,c))+'}' for c in configs)+'}')
(OUT/'test.cpp').write_text(cpp)
base=json.loads((NPC/'result/branch-v3/builds/B0-victim/manifest.json').read_text())
defines=[x for x in base['command'] if x.startswith('+define+')]
rtl=args.rtl.resolve()
sources=[rtl/'common'/f for f in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_axi4_pkg.sv','riscv32_pkg.sv']]
sources += [rtl/'core/frontend'/f for f in ['riscv32_btb.sv','riscv32_compact_btb.sv']]
command=['verilator','--cc','--exe','--build','--assert','-Wno-fatal','-j','2','--top-module','btb_test','--Mdir',str(OUT/'obj'),'-CFLAGS',f'-std=c++17 -I{TOOL}',*defines,*map(str,sources),str(OUT/'test.sv'),str(OUT/'test.cpp')]
manifest={'configs':configs,'command':command,'sources':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[TOOL/'btb_model.h',Path(__file__),OUT/'test.cpp',OUT/'test.sv']}}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
with (OUT/'build.log').open('x') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
with (OUT/'run.log').open('x') as log:subprocess.run([str(OUT/'obj/Vbtb_test')],stdout=log,stderr=subprocess.STDOUT,check=True)
print((OUT/'run.log').read_text())
