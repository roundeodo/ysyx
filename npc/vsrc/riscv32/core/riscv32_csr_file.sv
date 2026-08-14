module riscv32_csr_file
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  logic           csr_read_enable_i,
    input  logic    [11:0] csr_read_addr_i,
    // CSR数据属于XLEN宽架构状态；PC类CSR单独标注PC语义，避免误接物理总线地址。
    output xlen_data_t     csr_read_data_o,
    output logic           csr_read_illegal_o,

    input logic       csr_write_valid_i,
    input logic [11:0] csr_write_addr_i,
    input xlen_data_t csr_write_data_i,

    input logic retired_instruction_occurred_i,

    // CSR file只转发微架构事件，事件的定义与累计均由I-cache和PMU负责。
    input icache_event_t icache_event_i,
    input logic             trap_valid_i,
    input program_counter_t trap_pc_i,
    input xlen_data_t       trap_cause_i,
    input xlen_data_t       trap_tval_i,
    input logic             mret_valid_i,

    output program_counter_t mtvec_o,
    output program_counter_t mepc_o
);
  localparam logic [11:0] CSR_MVENDORID   = 12'hF11      ;
  localparam logic [11:0] CSR_MARCHID     = 12'hF12      ;
  localparam logic [11:0] CSR_MSTATUS     = 12'h300      ;
  localparam logic [11:0] CSR_MIE         = 12'h304      ;
  localparam logic [11:0] CSR_MTVEC       = 12'h305      ;
  localparam logic [11:0] CSR_MSCRATCH    = 12'h340      ;
  localparam logic [11:0] CSR_MEPC        = 12'h341      ;
  localparam logic [11:0] CSR_MCAUSE      = 12'h342      ;
  localparam logic [11:0] CSR_MTVAL       = 12'h343      ;
  localparam logic [11:0] CSR_MIP         = 12'h344      ;
  localparam logic [31:0] MVENDORID_VALUE = 32'h7973_7978;
  localparam logic [31:0] MARCHID_VALUE   = 32'h0150_BE98;

  // machine CSR随XLEN扩展；mtvec和mepc使用PC类型，其余保存普通架构状态。
  // mstatus的MIE/MPIE/MPP位号由规范固定，不会随XLEN移动。
  xlen_data_t       mstatus_q;
  xlen_data_t       mie_q;
  program_counter_t mtvec_q;
  xlen_data_t       mscratch_q;
  program_counter_t mepc_q;
  xlen_data_t       mcause_q;
  xlen_data_t       mtval_q;
  xlen_data_t       mip_q;

  // PMU负责把固定64位计数器转换成当前XLEN可见的CSR读窗口。
  logic       pmu_csr_read_select;
  xlen_data_t pmu_csr_read_data;

  // 不要从AXI握手推导hit/miss：一次miss会产生多次refill读，语义上不是多次cache miss。
  riscv32_pmu #(
      .RETIRE_SLOT_COUNT(1)
  ) u_pmu (
      .clk_i                      (clk_i),
      .rst_ni                     (rst_ni),
      .retired_instruction_count_i(retired_instruction_occurred_i),
      .icache_event_i             (icache_event_i),
      .csr_read_addr_i            (csr_read_addr_i),
      .csr_read_select_o          (pmu_csr_read_select),
      .csr_read_data_o            (pmu_csr_read_data),
      .csr_write_valid_i          (csr_write_valid_i),
      .csr_write_addr_i           (csr_write_addr_i),
      .csr_write_data_i           (csr_write_data_i)
  );

  always_comb begin
    csr_read_data_o    = '0;
    csr_read_illegal_o = 1'b0;

    if (csr_read_enable_i) begin
      unique case (csr_read_addr_i)
        // 固定32位实现常量显式转换到CSR访问宽度，避免依赖隐式零扩展。
        CSR_MVENDORID: csr_read_data_o = xlen_data_t'(MVENDORID_VALUE);
        CSR_MARCHID:   csr_read_data_o = xlen_data_t'(MARCHID_VALUE);
        CSR_MSTATUS:   csr_read_data_o = mstatus_q;
        CSR_MIE:       csr_read_data_o = mie_q;
        CSR_MTVEC:     csr_read_data_o = mtvec_q;
        CSR_MSCRATCH:  csr_read_data_o = mscratch_q;
        CSR_MEPC:      csr_read_data_o = mepc_q;
        CSR_MCAUSE:    csr_read_data_o = mcause_q;
        CSR_MTVAL:     csr_read_data_o = mtval_q;
        CSR_MIP:       csr_read_data_o = mip_q;
        default: begin
          if (pmu_csr_read_select) begin
            csr_read_data_o = pmu_csr_read_data;
          end else begin
            csr_read_data_o    = '0;
            csr_read_illegal_o = 1'b1;
          end
        end
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_q  <= '0;
      mie_q      <= '0;
      mtvec_q    <= '0;
      mscratch_q <= '0;
      mepc_q     <= '0;
      mcause_q   <= '0;
      mtval_q    <= '0;
      mip_q      <= '0;
    end else begin
      if (trap_valid_i) begin
        mepc_q           <= trap_pc_i;
        mcause_q         <= trap_cause_i;
        mtval_q          <= trap_tval_i;
        mstatus_q[7]     <= mstatus_q[3];
        mstatus_q[3]     <= 1'b0;
        mstatus_q[12:11] <= PRIV_MODE_M;
      end else if (mret_valid_i) begin
        mstatus_q[3]     <= mstatus_q[7];
        mstatus_q[7]     <= 1'b1;
        mstatus_q[12:11] <= PRIV_MODE_U;
      end else if (csr_write_valid_i) begin
        unique case (csr_write_addr_i)
          CSR_MSTATUS:  mstatus_q <= csr_write_data_i;
          CSR_MIE:      mie_q <= csr_write_data_i;
          CSR_MTVEC:    mtvec_q <= csr_write_data_i;
          CSR_MSCRATCH: mscratch_q <= csr_write_data_i;
          CSR_MEPC:     mepc_q <= csr_write_data_i;
          CSR_MCAUSE:   mcause_q <= csr_write_data_i;
          CSR_MTVAL:    mtval_q <= csr_write_data_i;
          CSR_MIP:      mip_q <= csr_write_data_i;
          default:      ;
        endcase
      end
    end
  end

  assign mtvec_o = mtvec_q;
  assign mepc_o  = mepc_q;

  // NOTE(P4): add privilege/write-legality checks and expose faults as precise
  // completion metadata. NOTE(P6): only ROB-authorized commit writes this state.

endmodule
