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

    input logic             trap_valid_i,
    input program_counter_t trap_pc_i,
    input xlen_data_t       trap_cause_i,
    input xlen_data_t       trap_tval_i,
    input logic             mret_valid_i,

    input  logic timer_interrupt_i,
    output logic timer_interrupt_enabled_o,

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

  localparam int unsigned MCAUSE_CODE_WIDTH = 4;

  xlen_data_t misa_value;
  logic       csr_addr_implemented;
  logic       csr_addr_read_only;
  xlen_data_t csr_selected_read_data;

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

  // 物理状态只保存当前M-mode实现真正可变的WARL字段；CSR读取时再恢复规范位号。
  // 这样不会为恒为0、恒为M-mode或因IALIGN固定的位分配触发器和写入选择逻辑。
  logic mstatus_mie_q;
  logic mstatus_mpie_q;
  logic mie_mtie_q;
  logic [XLEN-3:0] mtvec_base_q;
  xlen_data_t mscratch_q;
  logic [XLEN-3:0] mepc_base_q;
  logic mcause_interrupt_q;
  logic [MCAUSE_CODE_WIDTH-1:0] mcause_code_q;
  xlen_data_t mtval_q;

  xlen_data_t       mstatus_value;
  xlen_data_t       mie_value;
  program_counter_t mtvec_value;
  program_counter_t mepc_value;
  xlen_data_t       mcause_value;

  // PMU负责把固定64位计数器转换成当前XLEN可见的CSR读窗口。
  logic       pmu_csr_read_select;
  xlen_data_t pmu_csr_read_data;

  // PMU只实现软件可见的架构计数器。I-cache AMAT等分析状态属于仿真监视器，
  // 不应增加CSR file或流片核心的面积。
  riscv32_pmu #(
      .RETIRE_SLOT_COUNT(1)
  ) u_pmu (
      .clk_i                      (clk_i),
      .rst_ni                     (rst_ni),
      .retired_instruction_count_i(retired_instruction_occurred_i),
      .csr_read_addr_i            (csr_read_addr_i),
      .csr_read_select_o          (pmu_csr_read_select),
      .csr_read_data_o            (pmu_csr_read_data),
      .csr_write_valid_i          (csr_write_valid_i),
      .csr_write_addr_i           (csr_write_addr_i),
      .csr_write_data_i           (csr_write_data_i)
  );

  // MTIP 直接反映定时器电平，不受使能位影响，也不能由软件写 mip 清除。
  xlen_data_t mip_value;
  assign timer_interrupt_enabled_o = timer_interrupt_i && mie_mtie_q && mstatus_mie_q;

  // 当前只实现 M-mode，MPP 固定读作 M。
  always_comb begin
    mip_value = '0;
    mip_value[int'(IRQ_MACHINE_TIMER)] = timer_interrupt_i;
    mstatus_value        = '0;
    mstatus_value[12:11] = PRIV_MODE_M;
    mstatus_value[7]     = mstatus_mpie_q;
    mstatus_value[3]     = mstatus_mie_q;

    mie_value                       = '0;
    mie_value[int'(IRQ_MACHINE_TIMER)]    = mie_mtie_q;

    mtvec_value  = {mtvec_base_q, 2'b00};
    mepc_value   = {mepc_base_q, 2'b00};
    mcause_value = '0;
    mcause_value[XLEN-1] = mcause_interrupt_q;
    mcause_value[MCAUSE_CODE_WIDTH-1:0] = mcause_code_q;
  end

  // 地址译码同时产生读数据和implemented属性，避免为合法性检查再复制一套比较器。
  // 地址是否合法与CSR指令是否读取旧值是两件事。CSRRW rd=x0虽然不读旧值，
  // 仍然必须检查写地址是否存在以及是否只读。
  always_comb begin
    csr_addr_implemented  = 1'b1;
    csr_selected_read_data = '0;

    unique case (csr_read_addr_i)
      // 固定32位实现常量显式转换到CSR访问宽度，避免依赖隐式零扩展。
      CSR_MVENDORID: csr_selected_read_data = xlen_data_t'(MVENDORID_VALUE);
      CSR_MARCHID:   csr_selected_read_data = xlen_data_t'(MARCHID_VALUE);
      CSR_MIMPID:    csr_selected_read_data = '0;
      CSR_MHARTID:   csr_selected_read_data = '0;
      CSR_MSTATUS:   csr_selected_read_data = mstatus_value;
      CSR_MISA:      csr_selected_read_data = misa_value;
      CSR_MIE:       csr_selected_read_data = mie_value;
      CSR_MTVEC:     csr_selected_read_data = mtvec_value;
      CSR_MSCRATCH:  csr_selected_read_data = mscratch_q;
      CSR_MEPC:      csr_selected_read_data = mepc_value;
      CSR_MCAUSE:    csr_selected_read_data = mcause_value;
      CSR_MTVAL:     csr_selected_read_data = mtval_q;
      CSR_MIP:       csr_selected_read_data = mip_value;
      default: begin
        csr_addr_implemented   = pmu_csr_read_select;
        csr_selected_read_data = pmu_csr_read_data;
      end
    endcase

    csr_addr_read_only = csr_read_addr_i[11:10] == 2'b11;
    csr_read_illegal_o = (csr_read_enable_i || csr_access_write_enable_i) &&
                         (!csr_addr_implemented ||
                          (csr_access_write_enable_i && csr_addr_read_only));

    csr_read_data_o = '0;
    if (csr_read_enable_i && !csr_read_illegal_o) begin
      csr_read_data_o = csr_selected_read_data;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_mie_q       <= 1'b0;
      mstatus_mpie_q      <= 1'b0;
      mie_mtie_q           <= 1'b0;
      mtvec_base_q         <= '0;
      mscratch_q           <= '0;
      mepc_base_q          <= '0;
      mcause_interrupt_q   <= 1'b0;
      mcause_code_q        <= '0;
      mtval_q              <= '0;
    end else begin
      if (trap_valid_i) begin
        mepc_base_q        <= trap_pc_i[XLEN-1:2];
        mcause_interrupt_q <= trap_cause_i[XLEN-1];
        mcause_code_q      <= trap_cause_i[MCAUSE_CODE_WIDTH-1:0];
        mtval_q            <= trap_tval_i;
        mstatus_mpie_q     <= mstatus_mie_q;
        mstatus_mie_q      <= 1'b0;
      end else if (mret_valid_i) begin
        mstatus_mie_q  <= mstatus_mpie_q;
        mstatus_mpie_q <= 1'b1;
      end else if (csr_write_valid_i) begin
        unique case (csr_write_addr_i)
          CSR_MSTATUS: begin
            mstatus_mie_q  <= csr_write_data_i[3];
            mstatus_mpie_q <= csr_write_data_i[7];
          end
          CSR_MIE: begin
            mie_mtie_q <= csr_write_data_i[int'(IRQ_MACHINE_TIMER)];
          end
          // 第一版只支持Direct模式，低两位强制为0。
          CSR_MTVEC:    mtvec_base_q <= csr_write_data_i[XLEN-1:2];
          CSR_MSCRATCH: mscratch_q <= csr_write_data_i;
          // 未实现C扩展，IALIGN=32，因此mepc低两位均不可写。
          CSR_MEPC:     mepc_base_q <= csr_write_data_i[XLEN-1:2];
          // mcause是WLRL字段；只保存当前实现可能产生的中断位和4位cause code。
          CSR_MCAUSE: begin
            mcause_interrupt_q <= csr_write_data_i[XLEN-1];
            mcause_code_q      <= csr_write_data_i[MCAUSE_CODE_WIDTH-1:0];
          end
          CSR_MTVAL:    mtval_q <= csr_write_data_i;
          default:      ;
        endcase
      end
    end
  end

  assign mtvec_o = mtvec_value;
  assign mepc_o  = mepc_value;

  // NOTE(P4): add privilege/write-legality checks and expose faults as precise
  // completion metadata. NOTE(P6): only ROB-authorized commit writes this state.

endmodule
