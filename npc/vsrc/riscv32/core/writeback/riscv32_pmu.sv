module riscv32_pmu
  import riscv32_pkg::*;
#(
    parameter int unsigned RETIRE_SLOT_COUNT = 1
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic [$clog2(RETIRE_SLOT_COUNT + 1)-1:0] retired_instruction_count_i,

    input  logic [11:0] csr_read_addr_i,
    output logic        csr_read_select_o,
    output xlen_data_t  csr_read_data_o,

    input  logic        csr_write_valid_i,
    input  logic [11:0] csr_write_addr_i,
    input  xlen_data_t  csr_write_data_i
);
  // PMU只保存软件可见的架构性能计数器。Cache命中率、AMAT和总线延迟属于
  // 仿真分析数据，放在独立sim monitor中，避免把调试计数器综合进处理器。
  localparam logic [11:0] CSR_MCYCLE        = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET      = 12'hB02;
  localparam logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
  localparam logic [11:0] CSR_MCYCLEH       = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH     = 12'hB82;

  // 架构上mcycle/minstret均为64位。物理实现拆成两个32位计数段：低半每次
  // 累加，高半只在低半溢出时累加。这样保持64位CSR语义，同时把逐周期关键
  // 路径从64位进位链缩短为32位进位链。
  logic [31:0] mcycle_low_d;
  logic [31:0] mcycle_low_q;
  logic [31:0] mcycle_high_d;
  logic [31:0] mcycle_high_q;
  logic [31:0] minstret_low_d;
  logic [31:0] minstret_low_q;
  logic [31:0] minstret_high_d;
  logic [31:0] minstret_high_q;

  logic [32:0] minstret_low_sum;

  // mcountinhibit当前只实现CY(bit 0)和IR(bit 2)，因此只存两个真实状态位；
  // CSR读取时再重建规范定义的位位置，不为恒为0的保留位分配触发器。
  logic mcycle_inhibit_d;
  logic mcycle_inhibit_q;
  logic minstret_inhibit_d;
  logic minstret_inhibit_q;

  assign minstret_low_sum = {1'b0, minstret_low_q} + 33'(retired_instruction_count_i);

  // csr_read_select_o只表示当前地址由PMU实现。RV32通过H后缀CSR访问高32位，
  // RV64通过基础CSR一次访问完整64位；XLEN为静态配置，不产生运行时模式选择。
  always_comb begin
    csr_read_select_o = 1'b0;
    csr_read_data_o   = '0;

    unique case (csr_read_addr_i)
      CSR_MCYCLE: begin
        csr_read_select_o = 1'b1;
        if (XLEN == 32) begin
          csr_read_data_o = xlen_data_t'(mcycle_low_q);
        end else begin
          csr_read_data_o = xlen_data_t'({mcycle_high_q, mcycle_low_q});
        end
      end

      CSR_MCYCLEH: begin
        if (XLEN == 32) begin
          csr_read_select_o = 1'b1;
          csr_read_data_o   = xlen_data_t'(mcycle_high_q);
        end
      end

      CSR_MINSTRET: begin
        csr_read_select_o = 1'b1;
        if (XLEN == 32) begin
          csr_read_data_o = xlen_data_t'(minstret_low_q);
        end else begin
          csr_read_data_o = xlen_data_t'({minstret_high_q, minstret_low_q});
        end
      end

      CSR_MINSTRETH: begin
        if (XLEN == 32) begin
          csr_read_select_o = 1'b1;
          csr_read_data_o   = xlen_data_t'(minstret_high_q);
        end
      end

      CSR_MCOUNTINHIBIT: begin
        csr_read_select_o = 1'b1;
        csr_read_data_o   = xlen_data_t'({29'b0, minstret_inhibit_q,
            1'b0, mcycle_inhibit_q});
      end

      default: ;
    endcase
  end

  // 软件写计数器优先于自动累加。低半溢出和高半递增在同一时钟沿提交，
  // 因而对软件仍表现为连续的64位计数器。
  always_comb begin
    mcycle_low_d  = mcycle_low_q;
    mcycle_high_d = mcycle_high_q;

    if (csr_write_valid_i && (csr_write_addr_i == CSR_MCYCLE)) begin
      if (XLEN == 32) begin
        mcycle_low_d = csr_write_data_i[31:0];
      end else begin
        {mcycle_high_d, mcycle_low_d} = 64'(csr_write_data_i);
      end
    end else if ((XLEN == 32) && csr_write_valid_i &&
                 (csr_write_addr_i == CSR_MCYCLEH)) begin
      mcycle_high_d = csr_write_data_i[31:0];
    end else if (!mcycle_inhibit_q) begin
      mcycle_low_d = mcycle_low_q + 32'd1;
      if (&mcycle_low_q) begin
        mcycle_high_d = mcycle_high_q + 32'd1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mcycle_low_q  <= '0;
      mcycle_high_q <= '0;
    end else begin
      mcycle_low_q  <= mcycle_low_d;
      mcycle_high_q <= mcycle_high_d;
    end
  end

  always_comb begin
    minstret_low_d  = minstret_low_q;
    minstret_high_d = minstret_high_q;

    if (csr_write_valid_i && (csr_write_addr_i == CSR_MINSTRET)) begin
      if (XLEN == 32) begin
        minstret_low_d = csr_write_data_i[31:0];
      end else begin
        {minstret_high_d, minstret_low_d} = 64'(csr_write_data_i);
      end
    end else if ((XLEN == 32) && csr_write_valid_i &&
                 (csr_write_addr_i == CSR_MINSTRETH)) begin
      minstret_high_d = csr_write_data_i[31:0];
    end else if (!minstret_inhibit_q && (retired_instruction_count_i != '0)) begin
      minstret_low_d = minstret_low_sum[31:0];
      if (minstret_low_sum[32]) begin
        minstret_high_d = minstret_high_q + 32'd1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      minstret_low_q  <= '0;
      minstret_high_q <= '0;
    end else begin
      minstret_low_q  <= minstret_low_d;
      minstret_high_q <= minstret_high_d;
    end
  end

  always_comb begin
    mcycle_inhibit_d   = mcycle_inhibit_q;
    minstret_inhibit_d = minstret_inhibit_q;

    if (csr_write_valid_i && (csr_write_addr_i == CSR_MCOUNTINHIBIT)) begin
      mcycle_inhibit_d   = csr_write_data_i[0];
      minstret_inhibit_d = csr_write_data_i[2];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mcycle_inhibit_q   <= 1'b0;
      minstret_inhibit_q <= 1'b0;
    end else begin
      mcycle_inhibit_q   <= mcycle_inhibit_d;
      minstret_inhibit_q <= minstret_inhibit_d;
    end
  end

`ifndef SYNTHESIS
  logic pmu_csr_addr_implemented;

  // 地址实现判断必须和读窗口一致；RV64不实现H后缀的高半CSR。
  always_comb begin
    unique case (csr_read_addr_i)
      CSR_MCYCLE, CSR_MINSTRET, CSR_MCOUNTINHIBIT: pmu_csr_addr_implemented = 1'b1;
      CSR_MCYCLEH, CSR_MINSTRETH:                  pmu_csr_addr_implemented = (XLEN == 32);
      default:                                     pmu_csr_addr_implemented = 1'b0;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (int'(retired_instruction_count_i) <= RETIRE_SLOT_COUNT)
      else
        $error("PMU observed more retired instructions than available retire slots");

      assert (!csr_read_select_o || pmu_csr_addr_implemented)
      else
        $error("PMU selected an unimplemented CSR address");
    end
  end
`endif

endmodule
