// Diagnostic: execute real instructions through the unmodified core and observe
// a younger store at both the LSU boundary and an uncached AXI memory target.
module precise_exception_store_tb;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  axi4_manager_to_target_t instruction_request, data_request;
  axi4_target_to_manager_t instruction_response, data_response;
  riscv32_core #(.RESET_PC(32'h80000000)) dut (
    .clk_i(clk), .rst_ni(rst_n), .timer_interrupt_i(1'b0),
    .instruction_axi4_manager_o(instruction_request),
    .instruction_axi4_manager_i(instruction_response),
    .data_axi4_manager_o(data_request), .data_axi4_manager_i(data_response)
  );

  integer mode = 1; // 0: NOP, 1: illegal, 2: misaligned JAL, 3: ECALL
  integer cycle = 0;
  integer last_event_cycle = -1;
  integer traps = 0;
  integer accepted_stores = 0;
  integer physical_writes = 0;
  integer retired_stores = 0;
  logic [31:0] sentinel = 32'h12345678;
  logic instruction_read_present = 0;
  axi4_read_address_t instruction_address;
  integer instruction_beat = 0;
  logic data_read_present = 0;
  axi4_read_address_t data_read_address;
  integer read_delay = 0;
  logic write_address_present = 0;
  logic write_data_present = 0;
  axi4_write_address_t write_address;

  function automatic logic [31:0] instruction_word(input logic [31:0] address);
    case (address)
      32'h80000000: return 32'h0f0002b7; // lui t0,0xf000: uncached SRAM
      32'h80000004: return 32'h05500313; // addi t1,zero,0x55
      32'h80000008: return 32'h800003b7; // lui t2,0x80000
      32'h8000000c: return 32'h10038393; // addi t2,t2,0x100
      32'h80000010: return 32'h30539073; // csrw mtvec,t2
      32'h80000014: return 32'h0002ae03; // lw t3,0(t0): delayed 80 clocks
      32'h80000018: begin
        case (mode)
          1: return 32'hffffffff; // illegal instruction, not serializing
          2: return 32'h0020006f; // jal zero,+2: misaligned target
          3: return 32'h00000073; // ecall: serializing control case
          default: return 32'h00000013;
        endcase
      end
      32'h8000001c: return 32'h0062a223; // sw t1,4(t0): independent younger store
      32'h80000020, 32'h80000100: return 32'h0000006f; // loop / trap handler
      default: return 32'h00000013;
    endcase
  endfunction

  // Both AXI targets hold their responses until accepted. Instruction reads
  // support complete cacheline bursts; the data load intentionally stalls.
  always_comb begin
    instruction_response = '0;
    instruction_response.ar_ready = !instruction_read_present;
    instruction_response.r_valid = instruction_read_present;
    instruction_response.r.id = instruction_address.id;
    instruction_response.r.last = instruction_beat == int'(instruction_address.len);
    instruction_response.r.resp = AXI4_RESP_OKAY;
    instruction_response.r.data = instruction_word(instruction_address.addr + 32'(instruction_beat * 4));
    data_response = '0;
    data_response.ar_ready = !data_read_present;
    data_response.r_valid = data_read_present && read_delay == 0;
    data_response.r.id = data_read_address.id;
    data_response.r.last = 1'b1;
    data_response.r.resp = AXI4_RESP_OKAY;
    data_response.r.data = 32'habcd1234;
    data_response.aw_ready = !write_address_present;
    data_response.w_ready = write_address_present && !write_data_present;
    data_response.b_valid = write_address_present && write_data_present;
    data_response.b.id = write_address.id;
    data_response.b.resp = AXI4_RESP_OKAY;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cycle <= cycle + 1;
      if (instruction_request.ar_valid && instruction_response.ar_ready) begin
        instruction_read_present <= 1;
        instruction_address <= instruction_request.ar;
        instruction_beat <= 0;
      end
      if (instruction_response.r_valid && instruction_request.r_ready) begin
        if (instruction_response.r.last) instruction_read_present <= 0;
        else instruction_beat <= instruction_beat + 1;
      end
      if (data_request.ar_valid && data_response.ar_ready) begin
        assert (data_request.ar.addr == 32'h0f000000 && data_request.ar.len == 0)
          else $fatal(1, "unexpected data read");
        data_read_present <= 1;
        data_read_address <= data_request.ar;
        read_delay <= 80;
      end else if (read_delay > 0) read_delay <= read_delay - 1;
      if (data_response.r_valid && data_request.r_ready) data_read_present <= 0;
      if (data_request.aw_valid && data_response.aw_ready) begin
        $display("TRACE cycle=%0d AXI_AW addr=%h", cycle, data_request.aw.addr);
        assert (data_request.aw.addr == 32'h0f000004 && data_request.aw.len == 0)
          else $fatal(1, "unexpected data write");
        write_address_present <= 1;
        write_address <= data_request.aw;
      end
      if (data_request.w_valid && data_response.w_ready) begin
        $display("TRACE cycle=%0d AXI_W data=%h strb=%h", cycle, data_request.w.data, data_request.w.strb);
        assert (data_request.w.last) else $fatal(1, "unexpected store burst");
        for (int i = 0; i < 4; i++)
          if (data_request.w.strb[i]) sentinel[i*8+:8] <= data_request.w.data[i*8+:8];
        physical_writes <= physical_writes + 1;
        write_data_present <= 1;
      end
      if (data_response.b_valid && data_request.b_ready) begin
        write_address_present <= 0;
        write_data_present <= 0;
      end

      if (dut.resolved_execute_result_valid && dut.resolved_execute_result.uop.exception_valid)
        $display("TRACE cycle=%0d EX_EXCEPTION pc=%h serializing=%b ready=%b branch_redirect=%b issue_allowed=%b young_pc=%h young_valid=%b LSU_accept=%b",
          cycle, dut.resolved_execute_result.uop.pc, dut.resolved_execute_result.uop.serializing,
          dut.resolved_execute_result_ready, dut.execute_redirect_resolution_event,
          dut.execute_issue_allowed, dut.execute_packet.uop.pc, dut.execute_packet_valid,
          dut.lsu_req_valid && dut.lsu_req_ready);
      if (dut.lsu_req_valid && dut.lsu_req_ready && dut.lsu_req.uop.mem_ctrl.cmd == MEM_CMD_STORE) begin
        accepted_stores <= accepted_stores + 1;
        $display("TRACE cycle=%0d LSU_ACCEPT_STORE pc=%h", cycle, dut.lsu_req.uop.pc);
      end
      if (dut.data_memory_req_valid && dut.data_memory_req_ready && dut.data_memory_req.cmd == MEM_CMD_STORE)
        $display("TRACE cycle=%0d MEMORY_ACCEPT_STORE commit_redirect=%b", cycle, dut.commit_redirect_event);
      if (dut.commit_valid && dut.commit.trap_taken) begin
        traps <= traps + 1;
        last_event_cycle <= cycle;
        assert (dut.commit.pc == 32'h80000018) else $fatal(1, "wrong trap PC");
        assert (dut.commit.trap_cause_code == ((mode == 1) ? 2 : (mode == 2) ? 0 : 11))
          else $fatal(1, "wrong trap cause");
        $display("TRACE cycle=%0d WB_TRAP pc=%h cause=%0d redirect=%b LSU_state=%0d memory_valid=%b",
          cycle, dut.commit.pc, dut.commit.trap_cause_code, dut.commit_redirect_event,
          dut.u_lsu.state_q, dut.data_memory_req_valid);
      end
      if (dut.commit_valid && dut.commit.memory_access && dut.commit.memory_cmd == MEM_CMD_STORE) begin
        retired_stores <= retired_stores + 1;
        if (mode == 0) last_event_cycle <= cycle;
        $display("TRACE cycle=%0d COMMIT_STORE pc=%h", cycle, dut.commit.pc);
      end
      if (last_event_cycle >= 0 && cycle > last_event_cycle + 40) begin
        $display("RESULT mode=%0d traps=%0d accepted_stores=%0d physical_writes=%0d retired_stores=%0d sentinel=%h",
          mode, traps, accepted_stores, physical_writes, retired_stores, sentinel);
        if (mode == 0) begin
          assert (traps == 0 && physical_writes == 1 && retired_stores == 1 && sentinel == 32'h55)
            else $fatal(1, "normal store control failed");
        end else begin
          assert (traps == 1 && physical_writes == 0 && retired_stores == 0 && sentinel == 32'h12345678)
            else $fatal(1, "PRECISE_EXCEPTION_FAILURE: younger store escaped older trap");
        end
        $display("PASS precise exception control mode=%0d", mode);
        $finish;
      end
      if (cycle > 1000) $fatal(1, "test timed out");
    end
  end
  initial begin
    void'($value$plusargs("mode=%d", mode));
    repeat (5) @(negedge clk);
    rst_n = 1;
  end
endmodule
