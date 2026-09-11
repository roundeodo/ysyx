// 完整 CPU + 本地 CLINT + AXI 互联，执行交叉编译的 RV32 自检程序。
module riscv32_timer_system_tb;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  logic system_rst_n;
  always #5 clk = ~clk;
  axi4_manager_to_target_t request;
  axi4_target_to_manager_t response;
  riscv32_npc_system #(
      .RESET_PC(32'h8000_0000)
  ) dut (
      .clk_i                  (clk),
      .rst_ni                 (rst_n),
      .system_rst_no          (system_rst_n),
      .external_axi4_manager_o(request),
      .external_axi4_manager_i(response)
  );

  always @(posedge clk) begin
    if (!system_rst_n) begin
      assert (!request.ar_valid && !request.aw_valid && !request.w_valid)
        else $fatal(1, "System issued AXI traffic before reset release");
    end
  end

  logic [31:0] memory_array[32768];
  string image_path;
  integer delay_cycles = 0;
  integer am_test = 0;
  integer cycle_count = 0;
  logic read_present = 0;
  axi4_read_address_t read_address;
  integer read_delay = 0;
  logic [7:0] read_beat_index = 0;
  logic write_present = 0;
  logic write_data_received = 0;
  axi4_write_address_t write_address;
  integer write_delay = 0;
  integer physical_store_count = 0;
  integer accepted_store_count = 0;
  logic [7:0] write_beat_index = 0;
  integer committed_store_count = 0;
  integer interrupt_count = 0;
  integer pending_during_load_count = 0;
  integer pending_during_store_count = 0;
  integer pending_during_fault_count = 0;
  integer empty_frontend_interrupt_count = 0;
  integer retired_count = 0;
  integer fence_count = 0;
  logic [31:0] expected_pc = 32'h8000_0000;

  always_comb begin
    response          = '0;
    response.ar_ready = !read_present && (cycle_count % 3 != 0);
    response.r_valid  = read_present && (read_delay == 0);
    response.r.id     = read_address.id;
    response.r.last   = (read_beat_index == read_address.len);
    response.r.resp   = (read_address.addr == 32'h8001_e000) ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
    response.r.data   = memory_array[((read_address.addr-32'h8000_0000)>>2)+32'(read_beat_index)];
    response.aw_ready = !write_present && (cycle_count % 5 != 0);
    response.w_ready  = write_present && !write_data_received && (cycle_count % 7 != 0);
    response.b_valid  = write_present && write_data_received && (write_delay == 0);
    response.b.id     = write_address.id;
    response.b.resp   = AXI4_RESP_OKAY;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cycle_count <= cycle_count + 1;
      if (request.ar_valid && response.ar_ready) begin
        assert (request.ar.addr >= 32'h8000_0000 && request.ar.addr < 32'h8002_0000)
        else $fatal(1, "unexpected read address %h", request.ar.addr);
        read_present    <= 1;
        read_address    <= request.ar;
        read_beat_index <= 0;
        read_delay      <= (request.ar.addr == 32'h8001_e000) ? 6000 : delay_cycles;
      end else if (read_delay > 0) begin
        read_delay <= read_delay - 1;
      end
      if (response.r_valid && request.r_ready) begin
        if (response.r.last) read_present <= 0;
        else begin
          read_beat_index <= read_beat_index + 1;
          read_delay      <= delay_cycles / 4;
        end
      end
      if (request.aw_valid && response.aw_ready) begin
        assert (request.aw.addr >= 32'h8000_0000 &&
                request.aw.addr < 32'h8002_0000)
        else $fatal(1, "unexpected write");
        write_present <= 1;
        write_address <= request.aw;
        write_beat_index <= 0;
      end
      if (request.w_valid && response.w_ready) begin
        for (int byte_index = 0; byte_index < 4; byte_index++) begin
          if (request.w.strb[byte_index])
            memory_array[((write_address.addr - 32'h8000_0000) >> 2) + 32'(write_beat_index)][byte_index*8 +: 8]
              <= request.w.data[byte_index*8 +: 8];
        end
        physical_store_count <= physical_store_count + 1;
        assert (request.w.last == (write_beat_index == write_address.len))
        else $fatal(1, "invalid write burst last");
        write_beat_index <= write_beat_index + 1;
        write_data_received  <= request.w.last;
        write_delay          <= delay_cycles + 7;
      end else if (write_delay > 0) write_delay <= write_delay - 1;
      if (response.b_valid && request.b_ready) begin
        write_present       <= 0;
        write_data_received <= 0;
      end

      if (dut.timer_interrupt && dut.u_core.lsu_transaction_active && dut.u_core.timer_interrupt_enabled) begin
        if (write_present) pending_during_store_count <= pending_during_store_count + 1;
        if (read_present) begin
          pending_during_load_count <= pending_during_load_count + 1;
          if (read_address.addr == 32'h8001_e000)
            pending_during_fault_count <= pending_during_fault_count + 1;
        end
      end

      if (dut.u_core.lsu_req_valid && dut.u_core.lsu_req_ready &&
          dut.u_core.lsu_req.uop.mem_ctrl.cmd == MEM_CMD_STORE &&
          dut.u_core.lsu_req.effective_addr >= 32'h8000_0000)
        accepted_store_count <= accepted_store_count + 1;

      if (dut.u_core.interrupt_valid) begin
        assert (dut.u_core.trap_pc == expected_pc)
        else $fatal(1, "interrupt PC expected=%h actual=%h", expected_pc, dut.u_core.trap_pc);
        assert (!dut.u_core.commit_valid && !write_present)
        else $fatal(1, "interrupt interrupted an unfinished instruction/store");
        interrupt_count <= interrupt_count + 1;
        if (!dut.u_core.idu_fetch_entry_valid)
          empty_frontend_interrupt_count <= empty_frontend_interrupt_count + 1;
      end
      if (dut.u_core.commit_valid) begin
        assert (dut.u_core.commit.pc == expected_pc)
        else
          $fatal(
              1,
              "instruction lost/repeated expected=%h actual=%h",
              expected_pc,
              dut.u_core.commit.pc
          );
        if (!dut.u_core.commit.trap_taken) retired_count <= retired_count + 1;
        if (dut.u_core.committed_fence_i_occurred) fence_count <= fence_count + 1;
        if (dut.u_core.commit.memory_access && dut.u_core.commit.memory_cmd == MEM_CMD_STORE &&
            dut.u_core.commit.memory_addr >= 32'h8000_0000)
          committed_store_count <= committed_store_count + 1;
        expected_pc <= dut.u_core.commit.next_pc;
        if (dut.u_core.commit.system_op == SYS_EBREAK) begin
          assert (dut.u_core.u_arch_regfile.gpr_q[10] == 0)
          else
            $fatal(
                1,
                "software self-test failed: stage=%0d pc=%h",
                dut.u_core.u_arch_regfile.gpr_q[10],
                dut.u_core.commit.pc
            );
          assert ((am_test != 0) ? (interrupt_count == 5) :
                  (interrupt_count >= 11 && pending_during_fault_count > 0))
          else $fatal(1, "required interrupt coverage missing");
          if (am_test == 0) begin
            assert (physical_store_count > 0 && fence_count > 0)
            else $fatal(1, "dirty writeback/FENCE.I coverage missing");
            if (delay_cycles == 83)
              assert (pending_during_store_count > 0)
              else $fatal(1, "interrupt during dirty writeback was not exercised");
          end
          assert (accepted_store_count == committed_store_count)
          else
            $fatal(
                1,
                "store lost/repeated accepted=%0d committed=%0d",
                accepted_store_count,
                committed_store_count
            );
          $display(
              "PASS RV32 timer system am=%0d delay=%0d cycles=%0d irq=%0d retired=%0d write_beats=%0d pending_load=%0d pending_store=%0d pending_fault=%0d empty_frontend_irq=%0d",
              am_test, delay_cycles, cycle_count, interrupt_count, retired_count, physical_store_count,
              pending_during_load_count, pending_during_store_count, pending_during_fault_count,
              empty_frontend_interrupt_count);
          $finish;
        end
      end
      if (dut.u_core.commit_redirect_resolution_occurred)
        expected_pc <= dut.u_core.commit_redirect_req_at_resolution.target_pc;
      assert ({dut.u_core.u_csr_file.u_pmu.minstret_high_q, dut.u_core.u_csr_file.u_pmu.minstret_low_q} == 64'(retired_count))
      else $fatal(1, "interrupt or exception incorrectly counted as retired instruction");
      if (cycle_count > 500000) $fatal(1, "timeout pc=%h irq=%0d", expected_pc, interrupt_count);
    end
  end

  initial begin
    if (!$value$plusargs("image=%s", image_path)) $fatal(1, "missing +image");
    void'($value$plusargs("delay=%d", delay_cycles));
    void'($value$plusargs("am=%d", am_test));
    foreach (memory_array[index]) memory_array[index] = 0;
    $readmemh(image_path, memory_array);
    repeat (5) @(negedge clk);
    rst_n = 1;
  end
endmodule
