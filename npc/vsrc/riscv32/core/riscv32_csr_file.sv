module riscv32_csr_file
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  logic           csr_read_enable_i,
    input  logic    [11:0] csr_read_addr_i,
    input  logic           csr_access_write_enable_i,
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
  localparam logic [11:0] CSR_MSTATUS     = 12'h300;
  localparam logic [11:0] CSR_MISA        = 12'h301;
  localparam logic [11:0] CSR_MIE         = 12'h304;
  localparam logic [11:0] CSR_MTVEC       = 12'h305;
  localparam logic [11:0] CSR_MSCRATCH    = 12'h340;
  localparam logic [11:0] CSR_MEPC        = 12'h341;
  localparam logic [11:0] CSR_MCAUSE      = 12'h342;
  localparam logic [11:0] CSR_MTVAL       = 12'h343;
  localparam logic [11:0] CSR_MIP         = 12'h344;
  localparam logic [11:0] CSR_MVENDORID   = 12'hF11;
  localparam logic [11:0] CSR_MARCHID     = 12'hF12;
  localparam logic [11:0] CSR_MIMPID      = 12'hF13;
  localparam logic [11:0] CSR_MHARTID     = 12'hF14;
  localparam logic [31:0] MVENDORID_VALUE = 32'h7973_7978;
  localparam logic [31:0] MARCHID_VALUE   = 32'h0150_BE98;

  localparam xlen_data_t MSTATUS_RESET_VALUE = xlen_data_t'(32'h0000_1800);
  localparam xlen_data_t MSTATUS_WRITABLE_MASK =
      (xlen_data_t'(1) << 3) | (xlen_data_t'(1) << 7);
  localparam xlen_data_t MIE_WRITABLE_MASK =
      (xlen_data_t'(1) << IRQ_MACHINE_SOFTWARE) |
      (xlen_data_t'(1) << IRQ_MACHINE_TIMER) |
      (xlen_data_t'(1) << IRQ_MACHINE_EXTERNAL);

  xlen_data_t misa_value;
  logic       csr_addr_implemented;
  logic       csr_addr_read_only;
  logic       pmu_csr_addr_selected;

  // P3只实现M-mode。misa报告基础I扩展和当前MXL；不声明尚未实现的M/A/C/S/U能力。
  always_comb begin
    misa_value = '0;
    misa_value[8] = 1'b1;
    if (XLEN == 32) begin
      misa_value[XLEN-1 -: 2] = 2'b01;
    end else begin
      misa_value[XLEN-1 -: 2] = 2'b10;
    end
  end

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

  assign pmu_csr_addr_selected = pmu_csr_read_select;

  // 地址是否合法与CSR指令是否读取旧值是两件事。CSRRW rd=x0虽然不读旧值，
  // 仍然必须检查写地址是否存在以及是否只读。
  always_comb begin
    unique case (csr_read_addr_i)
      CSR_MSTATUS,
      CSR_MISA,
      CSR_MIE,
      CSR_MTVEC,
      CSR_MSCRATCH,
      CSR_MEPC,
      CSR_MCAUSE,
      CSR_MTVAL,
      CSR_MIP,
      CSR_MVENDORID,
      CSR_MARCHID,
      CSR_MIMPID,
      CSR_MHARTID: csr_addr_implemented = 1'b1;
      default:     csr_addr_implemented = pmu_csr_addr_selected;
    endcase

    csr_addr_read_only = csr_read_addr_i[11:10] == 2'b11;
    csr_read_illegal_o = (csr_read_enable_i || csr_access_write_enable_i) &&
                         (!csr_addr_implemented ||
                          (csr_access_write_enable_i && csr_addr_read_only));
  end

  always_comb begin
    csr_read_data_o    = '0;

    if (csr_read_enable_i && !csr_read_illegal_o) begin
      unique case (csr_read_addr_i)
        // 固定32位实现常量显式转换到CSR访问宽度，避免依赖隐式零扩展。
        CSR_MVENDORID: csr_read_data_o = xlen_data_t'(MVENDORID_VALUE);
        CSR_MARCHID:   csr_read_data_o = xlen_data_t'(MARCHID_VALUE);
        CSR_MIMPID:    csr_read_data_o = '0;
        CSR_MHARTID:   csr_read_data_o = '0;
        CSR_MSTATUS:   csr_read_data_o = mstatus_q;
        CSR_MISA:      csr_read_data_o = misa_value;
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
          end
        end
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_q  <= MSTATUS_RESET_VALUE;
      mie_q      <= '0;
      mtvec_q    <= '0;
      mscratch_q <= '0;
      mepc_q     <= '0;
      mcause_q   <= '0;
      mtval_q    <= '0;
      mip_q      <= '0;
    end else begin
      if (trap_valid_i) begin
        mepc_q           <= {trap_pc_i[XLEN-1:2], 2'b00};
        mcause_q         <= trap_cause_i;
        mtval_q          <= trap_tval_i;
        mstatus_q[7]     <= mstatus_q[3];
        mstatus_q[3]     <= 1'b0;
        mstatus_q[12:11] <= PRIV_MODE_M;
      end else if (mret_valid_i) begin
        mstatus_q[3]     <= mstatus_q[7];
        mstatus_q[7]     <= 1'b1;
        // 当前只实现M-mode，因此MPP是只读的M；加入U-mode时再扩展该WARL集合。
        mstatus_q[12:11] <= PRIV_MODE_M;
      end else if (csr_write_valid_i) begin
        unique case (csr_write_addr_i)
          CSR_MSTATUS: begin
            mstatus_q <= MSTATUS_RESET_VALUE |
                (csr_write_data_i & MSTATUS_WRITABLE_MASK);
          end
          CSR_MIE:      mie_q <= csr_write_data_i & MIE_WRITABLE_MASK;
          // 第一版只支持Direct模式，低两位强制为0。
          CSR_MTVEC:    mtvec_q <= {csr_write_data_i[XLEN-1:2], 2'b00};
          CSR_MSCRATCH: mscratch_q <= csr_write_data_i;
          // 未实现C扩展，IALIGN=32，因此mepc低两位均不可写。
          CSR_MEPC:     mepc_q <= {csr_write_data_i[XLEN-1:2], 2'b00};
          CSR_MCAUSE:   mcause_q <= csr_write_data_i;
          CSR_MTVAL:    mtval_q <= csr_write_data_i;
          // 当前没有接入可软件修改的pending位，mip保持只读0。
          CSR_MIP:      mip_q <= '0;
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
