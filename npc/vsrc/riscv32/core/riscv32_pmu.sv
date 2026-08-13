module riscv32_pmu
  import riscv32_pkg::*;
#(
    parameter int unsigned RETIRE_SLOT_COUNT = 1
) (
    input logic clk_i,
    input logic rst_ni,

    input logic [$clog2(RETIRE_SLOT_COUNT + 1)-1:0] retired_instruction_count_i,

    // 每个字段都是单周期事件脉冲。PMU只观察，不向cache或流水线反馈控制。
    input  icache_event_t            icache_event_i,
    input  logic          [    11:0] csr_read_addr_i,
    output logic                     csr_read_select_o,
    output logic          [XLEN-1:0] csr_read_data_o,

    input logic            csr_write_valid_i,
    input logic [    11:0] csr_write_addr_i,
    input logic [XLEN-1:0] csr_write_data_i
);
  // PMU (Performance Monitoring Unit) passively observes architectural or
  // microarchitectural events and accumulates how many times they occur. It must
  // never generate ready, stall, redirect, or other pipeline-control feedback.
  // Consequently, adding/removing a counter changes observations, not CPU behavior.
  //
  // Current observation path:
  //   core commit boundary
  //     -> count non-trapping instructions retired in this cycle
  //     -> retired_instruction_count_i
  //     -> minstret next-state addition
  //     -> software reads minstret/minstreth through the CSR file
  //
  // mcycle is different: its event source is this module's own active clock. It
  // increments once on each rising edge unless software inhibits it. Future cache
  // miss, branch-mispredict, or stall events should enter through explicit event
  // inputs and follow the same passive accumulation rule.

  // These addresses are the architectural names used by CSR instructions. PMU
  // owns their storage while riscv32_csr_file remains the common CSR access point.
  localparam logic [11:0] CSR_MCYCLE        = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET      = 12'hB02;
  localparam logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
  localparam logic [11:0] CSR_MCYCLEH       = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH     = 12'hB82;

  // mcycle counts active core clock cycles. Software combines mcycleh and mcycle
  // into one 64-bit value on RV32. It is the denominator of IPC.
  logic [63:0] mcycle_d;
  logic [63:0] mcycle_q;

  // minstret counts instructions that completed without taking a synchronous
  // exception. It is the numerator of IPC. Adding a count instead of a Boolean
  // makes the same state work when several instructions retire in one cycle.
  logic [63:0] minstret_d;
  logic [63:0] minstret_q;

  logic [63:0] retired_instruction_count_extended;

  assign retired_instruction_count_extended = {
    {(64 - $bits(retired_instruction_count_i)) {1'b0}}, retired_instruction_count_i
  };

  // mcountinhibit lets software stop selected counters. Only CY (bit 0) and IR
  // (bit 2) are implemented now. Other bits must always read as zero.
  logic [31:0] mcountinhibit_d;
  logic [31:0] mcountinhibit_q;

  // I-cache事件暂时作为内部硬件计数器；后续可映射到mhpmcounter CSR。
  logic [63:0] icache_lookup_count_d;
  logic [63:0] icache_lookup_count_q;
  logic [63:0] icache_hit_count_d;
  logic [63:0] icache_hit_count_q;
  logic [63:0] icache_miss_count_d;
  logic [63:0] icache_miss_count_q;
  logic [63:0] icache_refill_word_count_d;
  logic [63:0] icache_refill_word_count_q;
  logic [63:0] icache_refill_line_count_d;
  logic [63:0] icache_refill_line_count_q;
  logic [63:0] icache_uncached_access_count_d;
  logic [63:0] icache_uncached_access_count_q;
  logic [63:0] icache_stale_response_count_d;
  logic [63:0] icache_stale_response_count_q;

  // csr_read_select_o表示读地址由PMU实现，不是握手信号，也不表示计数器发生变化。
  // CSR file据此选择PMU读数据；未实现地址保持select为0，由CSR file报告非法访问。
  always_comb begin
    csr_read_select_o = 1'b0;
    csr_read_data_o   = '0;

    unique case (csr_read_addr_i)
      CSR_MCYCLE: begin
        csr_read_select_o = 1'b1;
        csr_read_data_o   = mcycle_q[31:0];
      end

      CSR_MCYCLEH: begin
        csr_read_select_o = 1'b1;
        csr_read_data_o   = mcycle_q[63:32];
      end

      CSR_MINSTRET: begin
        csr_read_select_o = 1'b1;
        csr_read_data_o   = minstret_q[31:0];
      end

      CSR_MINSTRETH: begin
        csr_read_select_o = 1'b1;
        csr_read_data_o   = minstret_q[63:32];
      end

      CSR_MCOUNTINHIBIT: begin
        csr_read_select_o = 1'b1;
        csr_read_data_o   = mcountinhibit_q;
      end

      default: ;
    endcase
  end

  // 软件写计数器的优先级高于同周期自动累加，避免写入值又被隐式加一。
  // mcountinhibit只实现CY(bit 0)和IR(bit 2)，其余位写入时强制清零。
  always_comb begin
    mcycle_d        = mcycle_q;
    minstret_d      = minstret_q;
    mcountinhibit_d = mcountinhibit_q;

    // mcycle
    if (csr_write_valid_i && (csr_write_addr_i == CSR_MCYCLE)) begin
      mcycle_d = {mcycle_q[63:32], csr_write_data_i};
    end else if (csr_write_valid_i && (csr_write_addr_i == CSR_MCYCLEH)) begin
      mcycle_d = {csr_write_data_i, mcycle_q[31:0]};
    end else if (!mcountinhibit_q[0]) begin
      mcycle_d = mcycle_q + 64'd1;
    end

    // minstret
    if (csr_write_valid_i && (csr_write_addr_i == CSR_MINSTRET)) begin
      minstret_d = {minstret_q[63:32], csr_write_data_i};
    end else if (csr_write_valid_i && (csr_write_addr_i == CSR_MINSTRETH)) begin
      minstret_d = {csr_write_data_i, minstret_q[31:0]};
    end else if (!mcountinhibit_q[2]) begin
      minstret_d = minstret_q + retired_instruction_count_extended;
    end

    if (csr_write_valid_i && (csr_write_addr_i == CSR_MCOUNTINHIBIT)) begin
      mcountinhibit_d = csr_write_data_i & 32'h0000_0005;
    end
  end

  // 当前事件是单bit脉冲，因此每类事件每周期最多累加一次。多发射版本应把
  // 事件字段扩展为计数值，使PMU直接累加实际发生数量。
  always_comb begin
    icache_lookup_count_d          = icache_lookup_count_q + 64'(icache_event_i.lookup_occurred);
    icache_hit_count_d             = icache_hit_count_q + 64'(icache_event_i.hit_occurred);
    icache_miss_count_d            = icache_miss_count_q + 64'(icache_event_i.miss_occurred);
    icache_refill_word_count_d     = icache_refill_word_count_q
                                     + 64'(icache_event_i.refill_word_occurred);
    icache_refill_line_count_d     = icache_refill_line_count_q
                                     + 64'(icache_event_i.refill_line_completed_occurred);
    icache_uncached_access_count_d = icache_uncached_access_count_q
                                     + 64'(icache_event_i.uncached_access_occurred);
    icache_stale_response_count_d  = icache_stale_response_count_q
                                     + 64'(icache_event_i.stale_response_discarded_occurred);
  end

  // I-cache计数器独立成组，避免与软件可写的mcycle/minstret更新优先级混杂。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      icache_lookup_count_q          <= '0;
      icache_hit_count_q             <= '0;
      icache_miss_count_q            <= '0;
      icache_refill_word_count_q     <= '0;
      icache_refill_line_count_q     <= '0;
      icache_uncached_access_count_q <= '0;
      icache_stale_response_count_q  <= '0;
    end else begin
      icache_lookup_count_q          <= icache_lookup_count_d;
      icache_hit_count_q             <= icache_hit_count_d;
      icache_miss_count_q            <= icache_miss_count_d;
      icache_refill_word_count_q     <= icache_refill_word_count_d;
      icache_refill_line_count_q     <= icache_refill_line_count_d;
      icache_uncached_access_count_q <= icache_uncached_access_count_d;
      icache_stale_response_count_q  <= icache_stale_response_count_d;
    end
  end

  // 三组软件可见状态分别更新，使每个寄存器组与自身语义保持相邻。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mcycle_q <= '0;
    end else begin
      mcycle_q <= mcycle_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      minstret_q <= '0;
    end else begin
      minstret_q <= minstret_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mcountinhibit_q <= '0;
    end else begin
      mcountinhibit_q <= mcountinhibit_d;
    end
  end

  logic pmu_csr_addr_implemented;

  always_comb begin
    unique case (csr_read_addr_i)
      CSR_MCYCLE,
      CSR_MCYCLEH,
      CSR_MINSTRET,
      CSR_MINSTRETH,
      CSR_MCOUNTINHIBIT: pmu_csr_addr_implemented = 1'b1;
      default:           pmu_csr_addr_implemented = 1'b0;
    endcase
  end

`ifndef SYNTHESIS
  // lookup先进入cache流水线，之后才被归类为hit、miss或uncached，因此累计分类数
  // 只能小于等于lookup数，不能要求每个周期都严格相等。访问异常也可能只计lookup。
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert ($unsigned(retired_instruction_count_i) <= RETIRE_SLOT_COUNT)
      else $error("PMU observed more retired instructions than available retire slots");

      assert ((mcountinhibit_q & ~32'h0000_0005) == 32'b0)
      else $error("PMU stored an unsupported mcountinhibit bit");

      assert (!csr_read_select_o || pmu_csr_addr_implemented)
      else $error("PMU selected an unimplemented CSR address");

      assert ((icache_hit_count_q + icache_miss_count_q +
               icache_uncached_access_count_q) <= icache_lookup_count_q)
      else $error("I-cache classified more requests than it accepted");

      assert (icache_refill_line_count_q <= icache_miss_count_q)
      else $error("I-cache completed more refill lines than cacheable misses");

      assert (icache_refill_word_count_q >=
              (icache_refill_line_count_q * ICACHE_WORDS_PER_LINE))
      else $error("I-cache completed a refill line without receiving all words");
    end
  end
`endif

endmodule
