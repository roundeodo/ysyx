module riscv32_privileged_tb;
  import riscv32_pkg::*;

  localparam logic [11:0] CSR_MSTATUS     = 12'h300;
  localparam logic [11:0] CSR_MISA        = 12'h301;
  localparam logic [11:0] CSR_MTVEC       = 12'h305;
  localparam logic [11:0] CSR_MSCRATCH    = 12'h340;
  localparam logic [11:0] CSR_MEPC        = 12'h341;
  localparam logic [11:0] CSR_MCAUSE      = 12'h342;
  localparam logic [11:0] CSR_MTVAL       = 12'h343;
  localparam logic [11:0] CSR_MCYCLE      = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET    = 12'hB02;
  localparam logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
  localparam logic [11:0] CSR_MCYCLEH     = 12'hB80;
  localparam logic [11:0] CSR_MVENDORID   = 12'hF11;

  logic clk;
  logic rst_n;

  logic       csr_read_enable;
  logic [11:0] csr_read_addr;
  logic       csr_access_write_enable;
  xlen_data_t csr_read_data;
  logic       csr_read_illegal;
  logic       csr_write_valid;
  logic [11:0] csr_write_addr;
  xlen_data_t csr_write_data;
  logic       retired_instruction_event;

  program_counter_t mtvec;
  program_counter_t mepc;
  logic             trap_valid;
  program_counter_t trap_pc;
  xlen_data_t       trap_cause;
  xlen_data_t       trap_tval;
  logic             mret_valid;
  redirect_req_t    trap_redirect;
  logic             trap_redirect_valid;

  writeback_result_t writeback_result;
  logic              writeback_result_valid;
  commit_t           commit;
  logic              commit_valid;
  xlen_data_t        gpr_write_data;
  arch_reg_idx_t     gpr_write_addr;
  logic              gpr_write_enable;

  always #1 clk = ~clk;

  riscv32_csr_file u_csr_file (
      .timer_interrupt_i(1'b0),
      .timer_interrupt_enabled_o(),
      .clk_i                         (clk),
      .rst_ni                        (rst_n),
      .csr_read_enable_i             (csr_read_enable),
      .csr_read_addr_i               (csr_read_addr),
      .csr_access_write_enable_i     (csr_access_write_enable),
      .csr_read_data_o               (csr_read_data),
      .csr_read_illegal_o            (csr_read_illegal),
      .csr_write_valid_i             (csr_write_valid),
      .csr_write_addr_i              (csr_write_addr),
      .csr_write_data_i              (csr_write_data),
      .retired_instruction_event_i(retired_instruction_event),
      .trap_valid_i                  (trap_valid),
      .trap_pc_i                     (trap_pc),
      .trap_cause_i                  (trap_cause),
      .trap_tval_i                   (trap_tval),
      .mret_valid_i                  (mret_valid),
      .mtvec_o                       (mtvec),
      .mepc_o                        (mepc)
  );

  riscv32_commit u_commit (
      .writeback_result_i      (writeback_result),
      .writeback_result_valid_i(writeback_result_valid),
      .writeback_result_ready_o(),
      .commit_o                (commit),
      .commit_valid_o          (commit_valid),
      .gpr_write_data_o        (gpr_write_data),
      .gpr_write_addr_o        (gpr_write_addr),
      .gpr_write_enable_o      (gpr_write_enable)
  );

  riscv32_trap_ctrl u_trap_ctrl (
      .interrupt_valid_i(1'b0),
      .interrupt_pc_i('0),
      .commit_i            (commit),
      .commit_valid_i      (commit_valid),
      .mtvec_i             (mtvec),
      .mepc_i              (mepc),
      .trap_valid_o        (trap_valid),
      .trap_pc_o           (trap_pc),
      .trap_cause_o        (trap_cause),
      .trap_tval_o         (trap_tval),
      .mret_valid_o        (mret_valid),
      .redirect_req_o      (trap_redirect),
      .redirect_req_valid_o(trap_redirect_valid)
  );

  task automatic read_csr(
      input logic [11:0] address,
      input xlen_data_t expected_data
  );
    csr_read_addr   = address;
    csr_read_enable = 1'b1;
    #1;
    assert (!csr_read_illegal && (csr_read_data == expected_data))
      else $fatal(1, "CSR read mismatch: XLEN=%0d addr=%h expected=%h actual=%h illegal=%b",
                  XLEN, address, expected_data, csr_read_data, csr_read_illegal);
    csr_read_enable = 1'b0;
  endtask

  task automatic write_csr(
      input logic [11:0] address,
      input xlen_data_t data
  );
    csr_write_addr  = address;
    csr_write_data  = data;
    csr_write_valid = 1'b1;
    @(posedge clk);
    #1;
    csr_write_valid = 1'b0;
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    csr_read_enable = 1'b0;
    csr_read_addr = '0;
    csr_access_write_enable = 1'b0;
    csr_write_valid = 1'b0;
    csr_write_addr = '0;
    csr_write_data = '0;
    retired_instruction_event = 1'b0;
    writeback_result = '0;
    writeback_result_valid = 1'b0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    #1;

    read_csr(CSR_MSTATUS, xlen_data_t'(32'h0000_1800));
    csr_read_addr = CSR_MISA;
    csr_read_enable = 1'b1;
    #1;
    assert (!csr_read_illegal && csr_read_data[8] &&
            (csr_read_data[XLEN-1 -: 2] == ((XLEN == 32) ? 2'b01 : 2'b10)))
      else $fatal(1, "misa does not report the selected RV32/RV64 I configuration");
    csr_read_enable = 1'b0;

    csr_read_addr = 12'h7c0;
    csr_read_enable = 1'b1;
    #1;
    assert (csr_read_illegal) else $fatal(1, "unknown CSR read was accepted");
    csr_read_enable = 1'b0;

    csr_read_addr = 12'h7c0;
    csr_access_write_enable = 1'b1;
    #1;
    assert (csr_read_illegal) else $fatal(1, "unknown CSRRW rd=x0 was accepted");
    csr_access_write_enable = 1'b0;

    csr_read_addr = CSR_MVENDORID;
    csr_access_write_enable = 1'b1;
    #1;
    assert (csr_read_illegal) else $fatal(1, "read-only CSR write was accepted");
    csr_access_write_enable = 1'b0;

    csr_read_addr = CSR_MCYCLEH;
    csr_read_enable = 1'b1;
    #1;
    assert (csr_read_illegal == (XLEN == 64))
      else $fatal(1, "mcycleh legality does not match XLEN");
    csr_read_enable = 1'b0;

    write_csr(CSR_MTVEC, xlen_data_t'(64'h0000_0000_8000_0103));
    assert (mtvec == program_counter_t'(64'h0000_0000_8000_0100))
      else $fatal(1, "mtvec direct-mode WARL alignment failed");
    write_csr(CSR_MEPC, xlen_data_t'(64'h0000_0000_8000_0227));
    assert (mepc == program_counter_t'(64'h0000_0000_8000_0224))
      else $fatal(1, "mepc IALIGN WARL alignment failed");
    write_csr(CSR_MSTATUS, '1);
    read_csr(CSR_MSTATUS, xlen_data_t'(32'h0000_1888));

    // Exception completion reaches commit but suppresses every normal side effect.
    writeback_result = '0;
    writeback_result.uop.pc = program_counter_t'(64'h8000_0040);
    writeback_result.uop.instruction = 32'hffff_ffff;
    writeback_result.uop.writes_rd = 1'b1;
    writeback_result.uop.rd = arch_reg_idx_t'(5);
    writeback_result.uop.csr_ctrl.write_enable = 1'b1;
    writeback_result.uop.csr_ctrl.addr = CSR_MSCRATCH;
    writeback_result.uop.mem_ctrl.cmd = MEM_CMD_STORE;
    writeback_result.uop.exception_valid = 1'b1;
    writeback_result.uop.exception_cause = EXC_ILLEGAL_INSTRUCTION;
    writeback_result.uop.exception_tval = xlen_data_t'(32'hffff_ffff);
    writeback_result_valid = 1'b1;
    #1;
    assert (commit_valid && commit.trap_taken && !commit.gpr_write &&
            !commit.csr_write && !commit.memory_access && !gpr_write_enable)
      else $fatal(1, "exception commit leaked a normal architectural side effect");
    assert (trap_redirect_valid && trap_redirect.reason == REDIRECT_TRAP &&
            trap_redirect.target_pc == program_counter_t'(64'h8000_0100))
      else $fatal(1, "trap redirect did not use aligned mtvec");
    @(posedge clk);
    #1;
    writeback_result_valid = 1'b0;
    read_csr(CSR_MEPC, program_counter_t'(64'h8000_0040));
    read_csr(CSR_MCAUSE, xlen_data_t'(EXC_ILLEGAL_INSTRUCTION));
    read_csr(CSR_MTVAL, xlen_data_t'(32'hffff_ffff));

    // MRET is itself a retired, non-trapping instruction and redirects to mepc.
    writeback_result = '0;
    writeback_result.uop.pc = program_counter_t'(64'h8000_0100);
    writeback_result.uop.system_op = SYS_MRET;
    writeback_result_valid = 1'b1;
    #1;
    assert (mret_valid && trap_redirect_valid &&
            trap_redirect.target_pc == program_counter_t'(64'h8000_0040))
      else $fatal(1, "mret redirect did not use mepc");
    @(posedge clk);
    #1;
    writeback_result_valid = 1'b0;
    read_csr(CSR_MSTATUS, xlen_data_t'(32'h0000_1888));

    // Freeze counters, then verify RV32 half-width and RV64 full-width CSR windows.
    write_csr(CSR_MCOUNTINHIBIT, xlen_data_t'(5));
    if (XLEN == 64) begin
      write_csr(CSR_MCYCLE, 64'h1122_3344_5566_7788);
      read_csr(CSR_MCYCLE, 64'h1122_3344_5566_7788);
      write_csr(CSR_MINSTRET, 64'h8877_6655_4433_2211);
      read_csr(CSR_MINSTRET, 64'h8877_6655_4433_2211);
    end else begin
      write_csr(CSR_MCYCLE, 32'h5566_7788);
      write_csr(CSR_MCYCLEH, 32'h1122_3344);
      read_csr(CSR_MCYCLE, 32'h5566_7788);
      read_csr(CSR_MCYCLEH, 32'h1122_3344);
    end

    $display("Privileged/commit/PMU directed test passed for XLEN=%0d", XLEN);
    $finish;
  end

endmodule : riscv32_privileged_tb
