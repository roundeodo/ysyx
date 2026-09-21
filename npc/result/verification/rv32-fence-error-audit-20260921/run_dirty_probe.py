from pathlib import Path
import json,subprocess,hashlib
out=Path(__file__).resolve().parent
npc=out.parents[2]
s=(npc/'tests/rtl/riscv32_dcache_tb.sv').read_text().split('  task automatic clean_cache')[0]
s=s.replace('module riscv32_dcache_tb;','module dirty_error_probe_tb;\n  bit inject_error=0, expected_fault=0;\n  int fault_mode=1;')
s=s.replace('axi_target.b.resp = AXI4_RESP_OKAY;','axi_target.b.resp = inject_error ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;')
s=s.replace('if (axi_manager.w.strb[byte_index]) begin','if (axi_manager.w.strb[byte_index] && !inject_error) begin')
s=s.replace('assert (!data_memory_resp.access_fault)','assert (data_memory_resp.access_fault == expected_fault)')
s+= '''
  initial begin
    core_data_t data;
    clk=0; rst_ni=0; data_memory_req='0; data_memory_req_valid=0;
    data_memory_resp_ready=1; clean_req=0;
    for(int i=0;i<TEST_MEMORY_BYTES;i++) memory_byte_array[i]=0;
    if($value$plusargs("fault=%d",fault_mode)) begin end
    repeat(4) @(negedge clk); rst_ni=1;
    issue_memory_request(TEST_ADDR_A,MEM_CMD_STORE,32'hdeadbeef,'1,0,data);
    issue_memory_request(TEST_ADDR_A,MEM_CMD_LOAD,0,0,1,data);
    assert(data==32'hdeadbeef) else $fatal(1,"store did not reach the cache");
    $display("BEFORE_EVICTION A=%h cache_value=%h backing_value=%h", TEST_ADDR_A,data,read_memory_word(TEST_ADDR_A));
    issue_memory_request(TEST_ADDR_B,MEM_CMD_LOAD,0,0,2,data);
    inject_error=(fault_mode!=0); expected_fault=inject_error;
    issue_memory_request(TEST_ADDR_C,MEM_CMD_LOAD,0,0,3,data);
    $display("EVICTION access_fault=%b writebacks=%0d",expected_fault,write_address_handshake_count);
    inject_error=0; expected_fault=0;
    issue_memory_request(TEST_ADDR_A,MEM_CMD_LOAD,0,0,0,data);
    $display("AFTER_EVICTION A=%h returned=%h expected=deadbeef fault=0",TEST_ADDR_A,data);
    if((fault_mode==0 && data!=32'hdeadbeef) || (fault_mode!=0 && data!=0))
      $fatal(1,"probe result differs from the predicted path");
    $finish;
  end
  initial begin #100000; $fatal(1,"probe timed out"); end
endmodule
'''
p=out/'dirty_error_probe_tb.sv';p.write_text(s)
old=json.loads((out/'manifest.json').read_text())['command']
cmd=old[:old.index('--top-module')]+['--top-module','dirty_error_probe_tb','--Mdir',str(out/'obj-dirty')]
rtl=npc/'vsrc/riscv32'
sources=[rtl/'common'/f for f in ['riscv_config_pkg.sv','riscv32_addr_map_pkg.sv','riscv32_axi4_pkg.sv','riscv32_pkg.sv']]+[rtl/'core/memory'/f'riscv32_{m}.sv' for m in ['dcache_tag_array','dcache_data_array','dcache_axi','dcache_miss_unit','dcache']]+[p]
cmd+=list(map(str,sources))
(out/'dirty-manifest.json').write_text(json.dumps({'command':cmd,'source_hashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}},indent=2))
with (out/'dirty-build.log').open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
if r.returncode: print((out/'dirty-build.log').read_text()[-4000:]);raise SystemExit(r.returncode)
for mode in [0,1]:
 with (out/f'dirty-fault-{mode}.log').open('w') as f:
  r=subprocess.run([str(out/'obj-dirty/Vdirty_error_probe_tb'),f'+fault={mode}'],stdout=f,stderr=subprocess.STDOUT)
 print('mode',mode,'exit',r.returncode,(out/f'dirty-fault-{mode}.log').read_text())
