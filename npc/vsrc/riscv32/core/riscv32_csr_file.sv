module riscv32_csr_file
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  logic            csr_read_enable_i,
    input  logic [    11:0] csr_read_addr_i,
    output logic [XLEN-1:0] csr_read_data_o,
    output logic            csr_read_illegal_o,

    input logic            csr_write_valid_i,
    input logic [    11:0] csr_write_addr_i,
    input logic [XLEN-1:0] csr_write_data_i,

    input logic retired_instruction_occurred_i,

    // CSR file只转发微架构事件，事件的定义与累计均由I-cache和PMU负责。
    input icache_event_t icache_event_i,
    input logic                     trap_valid_i,
    input logic          [XLEN-1:0] trap_pc_i,
    input logic          [XLEN-1:0] trap_cause_i,
    input logic          [XLEN-1:0] trap_tval_i,
    input logic                     mret_valid_i,

    input  logic timer_interrupt_i,
    output logic timer_interrupt_enabled_o,

    output logic [XLEN-1:0] mtvec_o,
    output logic [XLEN-1:0] mepc_o
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

  logic [    31:0] mstatus_q;
  logic [    31:0] mie_q;
  logic [    31:0] mtvec_q;
  logic [    31:0] mscratch_q;
  logic [    31:0] mepc_q;
  logic [    31:0] mcause_q;
  logic [    31:0] mtval_q;
  logic [    31:0] mip;

  // MTIP 只反映硬件电平；软件通过 mtimecmp 清除请求，通过 MIE/MTIE 屏蔽。
  assign mip = {24'b0, timer_interrupt_i, 7'b0};
  assign timer_interrupt_enabled_o = timer_interrupt_i && mie_q[7] && mstatus_q[3];

  logic            pmu_csr_read_select;
  logic [XLEN-1:0] pmu_csr_read_data;

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
        CSR_MVENDORID: csr_read_data_o = MVENDORID_VALUE;
        CSR_MARCHID:   csr_read_data_o = MARCHID_VALUE;
        CSR_MSTATUS:   csr_read_data_o = mstatus_q;
        CSR_MIE:       csr_read_data_o = mie_q;
        CSR_MTVEC:     csr_read_data_o = mtvec_q;
        CSR_MSCRATCH:  csr_read_data_o = mscratch_q;
        CSR_MEPC:      csr_read_data_o = mepc_q;
        CSR_MCAUSE:    csr_read_data_o = mcause_q;
        CSR_MTVAL:     csr_read_data_o = mtval_q;
        CSR_MIP:       csr_read_data_o = mip;
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
      mstatus_q  <= 32'h0000_1800;
      mie_q      <= '0;
      mtvec_q    <= '0;
      mscratch_q <= '0;
      mepc_q     <= '0;
      mcause_q   <= '0;
      mtval_q    <= '0;
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
        mstatus_q[12:11] <= PRIV_MODE_M;
      end else if (csr_write_valid_i) begin
        unique case (csr_write_addr_i)
          CSR_MSTATUS:  mstatus_q <= (csr_write_data_i & 32'h0000_0088) | 32'h0000_1800;
          CSR_MIE:      mie_q <= csr_write_data_i & 32'h0000_0080;
          CSR_MTVEC:    mtvec_q <= {csr_write_data_i[31:2], 2'b00};
          CSR_MSCRATCH: mscratch_q <= csr_write_data_i;
          CSR_MEPC:     mepc_q <= {csr_write_data_i[31:2], 2'b00};
          CSR_MCAUSE:   mcause_q <= csr_write_data_i;
          CSR_MTVAL:    mtval_q <= csr_write_data_i;
          CSR_MIP:      ; // MTIP 为硬件只读，未实现的 pending 位固定为 0。
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
