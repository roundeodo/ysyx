module riscv32_pmu
  import riscv32_pkg::*;
#(
    parameter int unsigned RETIRE_SLOT_COUNT = 1
) (
    input logic clk_i,
    input logic rst_ni,

    input logic [$clog2(RETIRE_SLOT_COUNT + 1)-1:0] retired_instruction_count_i,

    // 每个字段都是单周期事件脉冲。PMU只观察，不向cache或流水线反馈控制。
    input  icache_event_t        icache_event_i,
    input  logic          [11:0] csr_read_addr_i,
    output logic                 csr_read_select_o,
    // CSR访问宽度由XLEN决定；64位计数器的存储宽度不随CSR端口变化。
    output xlen_data_t           csr_read_data_o,

    input logic              csr_write_valid_i,
    input logic       [11:0] csr_write_addr_i,
    input xlen_data_t        csr_write_data_i
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

  // mcycle/minstret是架构定义的64位计数器。RV32分两次访问，RV64一次整宽访问。
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

  // AMAT只统计cacheable lookup。hit/miss response latency从lookup请求被cache
  // 接收开始，到对应lookup response首次有效为止，不包含IFU接收反压。完整refill latency单独
  // 从miss分配计到末一个refill word握手，用于表示blocking cache的占用时间。
  logic [63:0] icache_miss_response_count_d;
  logic [63:0] icache_miss_response_count_q;
  logic [63:0] icache_refill_transaction_count_d;
  logic [63:0] icache_refill_transaction_count_q;
  logic [63:0] icache_lookup_request_wait_cycle_count_d;
  logic [63:0] icache_lookup_request_wait_cycle_count_q;
  logic [63:0] icache_hit_latency_cycle_sum_d;
  logic [63:0] icache_hit_latency_cycle_sum_q;
  logic [63:0] icache_miss_response_latency_cycle_sum_d;
  logic [63:0] icache_miss_response_latency_cycle_sum_q;
  logic [63:0] icache_refill_latency_cycle_sum_d;
  logic [63:0] icache_refill_latency_cycle_sum_q;

  // 当前IFU最多只有一个lookup在途，因此一个计时器就能精确匹配请求和响应。
  // 未来允许多请求在途时，必须改为按frontend tag保存起始时间，不能共享此计时器。
  logic [63:0] icache_lookup_elapsed_cycle_count_d;
  logic [63:0] icache_lookup_elapsed_cycle_count_q;
  logic [63:0] icache_refill_elapsed_cycle_count_d;
  logic [63:0] icache_refill_elapsed_cycle_count_q;
  logic        icache_lookup_timer_active_d;
  logic        icache_lookup_timer_active_q;
  logic        icache_lookup_miss_classification_d;
  logic        icache_lookup_miss_classification_q;
  logic        icache_refill_timer_active_d;
  logic        icache_refill_timer_active_q;

  // response present可能因下游反压保持多拍。只有PMU仍在跟踪请求，或请求和结果
  // 同拍出现时，当前present才表示一个尚未统计的新结果。
  logic        icache_lookup_response_available_for_active_request;

  assign icache_lookup_response_available_for_active_request =
      icache_event_i.lookup_response_present &&
      (icache_lookup_timer_active_q || icache_event_i.lookup_occurred);

  // csr_read_select_o表示读地址由PMU实现，不是握手信号，也不表示计数器发生变化。
  // CSR file据此选择PMU读数据；未实现地址保持select为0，由CSR file报告非法访问。
  // RV32通过基础CSR和H后缀CSR分别访问低、高32位；RV64通过基础CSR访问全部64位。
  // XLEN是静态配置，因此下面的条件会在 elaboration 时化简，不形成动态模式选择器。
  always_comb begin
    csr_read_select_o = 1'b0;
    csr_read_data_o   = '0;

    unique case (csr_read_addr_i)
      CSR_MCYCLE: begin
        csr_read_select_o = 1'b1;
        if (XLEN == 32) begin
          csr_read_data_o = xlen_data_t'(mcycle_q[31:0]);
        end else begin
          csr_read_data_o = xlen_data_t'(mcycle_q);
        end
      end

      CSR_MCYCLEH: begin
        if (XLEN == 32) begin
          csr_read_select_o = 1'b1;
          csr_read_data_o   = xlen_data_t'(mcycle_q[63:32]);
        end
      end

      CSR_MINSTRET: begin
        csr_read_select_o = 1'b1;
        if (XLEN == 32) begin
          csr_read_data_o = xlen_data_t'(minstret_q[31:0]);
        end else begin
          csr_read_data_o = xlen_data_t'(minstret_q);
        end
      end

      CSR_MINSTRETH: begin
        if (XLEN == 32) begin
          csr_read_select_o = 1'b1;
          csr_read_data_o   = xlen_data_t'(minstret_q[63:32]);
        end
      end

      CSR_MCOUNTINHIBIT: begin
        csr_read_select_o = 1'b1;
        csr_read_data_o   = xlen_data_t'(mcountinhibit_q);
      end

      default: ;
    endcase
  end

  // 软件写计数器的优先级高于同周期自动累加，避免写入值又被隐式加一。
  // mcountinhibit只实现CY(bit 0)和IR(bit 2)，其余位写入时强制清零。
  // 软件写入优先于自动累加。RV32只覆盖被访问的半字，RV64基础CSR覆盖全部64位。
  always_comb begin
    mcycle_d        = mcycle_q;
    minstret_d      = minstret_q;
    mcountinhibit_d = mcountinhibit_q;

    // mcycle
    if (csr_write_valid_i && (csr_write_addr_i == CSR_MCYCLE)) begin
      if (XLEN == 32) begin
        mcycle_d = {mcycle_q[63:32], csr_write_data_i[31:0]};
      end else begin
        mcycle_d = 64'(csr_write_data_i);
      end
    end else if ((XLEN == 32) && csr_write_valid_i && (csr_write_addr_i == CSR_MCYCLEH)) begin
      mcycle_d = {csr_write_data_i[31:0], mcycle_q[31:0]};
    end else if (!mcountinhibit_q[0]) begin
      mcycle_d = mcycle_q + 64'd1;
    end

    // minstret
    if (csr_write_valid_i && (csr_write_addr_i == CSR_MINSTRET)) begin
      if (XLEN == 32) begin
        minstret_d = {minstret_q[63:32], csr_write_data_i[31:0]};
      end else begin
        minstret_d = 64'(csr_write_data_i);
      end
    end else if ((XLEN == 32) && csr_write_valid_i && (csr_write_addr_i == CSR_MINSTRETH)) begin
      minstret_d = {csr_write_data_i[31:0], minstret_q[31:0]};
    end else if (!mcountinhibit_q[2]) begin
      minstret_d = minstret_q + retired_instruction_count_extended;
    end

    if (csr_write_valid_i && (csr_write_addr_i == CSR_MCOUNTINHIBIT)) begin
      mcountinhibit_d = 32'(csr_write_data_i) & 32'h0000_0005;
    end
  end

  // 当前事件是单bit脉冲，因此每类事件每周期最多累加一次。多发射版本应把
  // 事件字段扩展为计数值，使PMU直接累加实际发生数量。
  always_comb begin
    icache_lookup_count_d          = icache_lookup_count_q + 64'(icache_event_i.lookup_occurred);
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

  // Lookup计时与事件计数分开：hit在响应首次可用时直接分类；miss先在S2
  // 分类，之后critical word才产生通用lookup response。计时不等待response ready，
  // 因而不会把fetch buffer或后端反压算入cache AMAT。uncached和access fault会
  // 正常结束lookup计时器，但不进入cacheable AMAT的分子或分母。
  always_comb begin
    icache_hit_count_d                       = icache_hit_count_q;
    icache_miss_response_count_d             = icache_miss_response_count_q;
    icache_refill_transaction_count_d        = icache_refill_transaction_count_q;
    icache_lookup_request_wait_cycle_count_d =
                                               icache_lookup_request_wait_cycle_count_q + 64'(icache_event_i.lookup_request_waiting);
    icache_hit_latency_cycle_sum_d           = icache_hit_latency_cycle_sum_q;
    icache_miss_response_latency_cycle_sum_d = icache_miss_response_latency_cycle_sum_q;
    icache_refill_latency_cycle_sum_d        = icache_refill_latency_cycle_sum_q;
    icache_lookup_elapsed_cycle_count_d      = icache_lookup_elapsed_cycle_count_q;
    icache_refill_elapsed_cycle_count_d      = icache_refill_elapsed_cycle_count_q;
    icache_lookup_timer_active_d             = icache_lookup_timer_active_q;
    icache_lookup_miss_classification_d      = icache_lookup_miss_classification_q;
    icache_refill_timer_active_d             = icache_refill_timer_active_q;

    if (icache_lookup_timer_active_q) begin
      icache_lookup_elapsed_cycle_count_d = icache_lookup_elapsed_cycle_count_q + 64'd1;
    end
    if (icache_refill_timer_active_q) begin
      icache_refill_elapsed_cycle_count_d = icache_refill_elapsed_cycle_count_q + 64'd1;
    end

    if (icache_event_i.miss_occurred) begin
      icache_lookup_miss_classification_d = 1'b1;
      icache_refill_timer_active_d        = 1'b1;
      icache_refill_elapsed_cycle_count_d = '0;
    end

    // response首次可用时结束当前lookup。对于hit，cache同时给出命中分类；
    // 对于miss，使用之前锁存的S2分类。“已经过的周期+1”把响应当拍计入延迟。
    if (icache_lookup_response_available_for_active_request) begin
      if (icache_event_i.lookup_response_is_cache_hit) begin
        icache_hit_count_d             = icache_hit_count_q + 64'd1;
        icache_hit_latency_cycle_sum_d = icache_hit_latency_cycle_sum_q +
                                         icache_lookup_elapsed_cycle_count_q + 64'd1;
      end else if (icache_lookup_miss_classification_q || icache_event_i.miss_occurred) begin
        icache_miss_response_count_d             = icache_miss_response_count_q + 64'd1;
        icache_miss_response_latency_cycle_sum_d =
                                                   icache_miss_response_latency_cycle_sum_q +
                                                   icache_lookup_elapsed_cycle_count_q + 64'd1;
      end

      icache_lookup_elapsed_cycle_count_d = '0;
      icache_lookup_timer_active_d        = 1'b0;
      icache_lookup_miss_classification_d = 1'b0;
    end

    // 允许“旧响应可用+新请求接收”同拍发生。如果当前没有旧lookup且请求
    // 与响应同拍，该请求已以1拍延迟完成，不再留下活动计时器。
    if (icache_event_i.lookup_occurred &&
        (!icache_event_i.lookup_response_present || icache_lookup_timer_active_q)) begin
      icache_lookup_elapsed_cycle_count_d = '0;
      icache_lookup_timer_active_d        = 1'b1;
      icache_lookup_miss_classification_d = 1'b0;
    end

    if (icache_event_i.refill_transaction_completed_occurred) begin
      icache_refill_transaction_count_d   = icache_refill_transaction_count_q + 64'd1;
      icache_refill_latency_cycle_sum_d   = icache_refill_latency_cycle_sum_q +
                                            icache_refill_elapsed_cycle_count_q + 64'd1;
      icache_refill_elapsed_cycle_count_d = '0;
      icache_refill_timer_active_d        = 1'b0;
    end
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

  // AMAT统计状态独立更新，不向I-cache或流水线生成任何控制信号。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      icache_miss_response_count_q             <= '0;
      icache_refill_transaction_count_q        <= '0;
      icache_lookup_request_wait_cycle_count_q <= '0;
      icache_hit_latency_cycle_sum_q           <= '0;
      icache_miss_response_latency_cycle_sum_q <= '0;
      icache_refill_latency_cycle_sum_q        <= '0;
      icache_lookup_elapsed_cycle_count_q      <= '0;
      icache_refill_elapsed_cycle_count_q      <= '0;
      icache_lookup_timer_active_q             <= 1'b0;
      icache_lookup_miss_classification_q      <= 1'b0;
      icache_refill_timer_active_q             <= 1'b0;
    end else begin
      icache_miss_response_count_q             <= icache_miss_response_count_d;
      icache_refill_transaction_count_q        <= icache_refill_transaction_count_d;
      icache_lookup_request_wait_cycle_count_q <= icache_lookup_request_wait_cycle_count_d;
      icache_hit_latency_cycle_sum_q           <= icache_hit_latency_cycle_sum_d;
      icache_miss_response_latency_cycle_sum_q <= icache_miss_response_latency_cycle_sum_d;
      icache_refill_latency_cycle_sum_q        <= icache_refill_latency_cycle_sum_d;
      icache_lookup_elapsed_cycle_count_q      <= icache_lookup_elapsed_cycle_count_d;
      icache_refill_elapsed_cycle_count_q      <= icache_refill_elapsed_cycle_count_d;
      icache_lookup_timer_active_q             <= icache_lookup_timer_active_d;
      icache_lookup_miss_classification_q      <= icache_lookup_miss_classification_d;
      icache_refill_timer_active_q             <= icache_refill_timer_active_d;
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

  // 地址实现判断必须和读窗口一致；RV64不实现H后缀的高半CSR。
  always_comb begin
    unique case (csr_read_addr_i)
      CSR_MCYCLE, CSR_MINSTRET, CSR_MCOUNTINHIBIT: pmu_csr_addr_implemented = 1'b1;
      CSR_MCYCLEH, CSR_MINSTRETH:                  pmu_csr_addr_implemented = (XLEN == 32);
      default:                                     pmu_csr_addr_implemented = 1'b0;
    endcase
  end

`ifndef SYNTHESIS
  function automatic real calculate_average_cycles(input logic [63:0] cycle_sum,
                                                   input logic [63:0] event_count);
    if (event_count == 0) begin
      return 0.0;
    end
    return real'(cycle_sum) / real'(event_count);
  endfunction

  function automatic real calculate_percentage(input logic [63:0] event_count,
                                               input logic [63:0] total_count);
    if (total_count == 0) begin
      return 0.0;
    end
    return 100.0 * real'(event_count) / real'(total_count);
  endfunction

  function automatic real calculate_miss_penalty();
    if ((icache_hit_count_q == 0) || (icache_miss_response_count_q == 0)) begin
      return 0.0;
    end
    return calculate_average_cycles(
        icache_miss_response_latency_cycle_sum_q, icache_miss_response_count_q
    ) - calculate_average_cycles(
        icache_hit_latency_cycle_sum_q, icache_hit_count_q
    );
  endfunction

  // 浮点计算只存在于仿真输出。可综合PMU只累计整数事件和周期，
  // 不在硬件中为一次性报告实现除法器。AMAT直接使用已完成的cacheable
  // response延迟总和；数学上与 hit_latency + miss_rate * miss_penalty 等价。
  final begin
    if ((icache_hit_count_q + icache_miss_response_count_q) != 0) begin
      $display("");
      $display("================ I-cache AMAT counters ===================");
      $display("lookups / cacheable hits / cacheable misses : %0d / %0d / %0d",
               icache_lookup_count_q, icache_hit_count_q, icache_miss_count_q);
      $display("I-cache hit rate                            : %.3f%%", calculate_percentage(
               icache_hit_count_q, icache_hit_count_q + icache_miss_count_q));
      $display("average hit response latency                : %.3f cycles",
               calculate_average_cycles(icache_hit_latency_cycle_sum_q, icache_hit_count_q));
      $display("average miss critical response latency      : %.3f cycles",
               calculate_average_cycles(icache_miss_response_latency_cycle_sum_q,
                                        icache_miss_response_count_q));
      $display("average miss penalty                        : %.3f cycles",
               calculate_miss_penalty());
      $display("I-cache AMAT                                : %.3f cycles",
               calculate_average_cycles(
               icache_hit_latency_cycle_sum_q + icache_miss_response_latency_cycle_sum_q,
               icache_hit_count_q + icache_miss_response_count_q));
      $display("average complete refill latency             : %.3f cycles",
               calculate_average_cycles(icache_refill_latency_cycle_sum_q,
                                        icache_refill_transaction_count_q));
      $display("lookup request waiting cycles               : %0d",
               icache_lookup_request_wait_cycle_count_q);
      $display("successful line installs / refill finishes  : %0d / %0d",
               icache_refill_line_count_q, icache_refill_transaction_count_q);
      $display("==========================================================");
    end
  end

  // lookup先进入cache流水线，之后才被归类为hit、miss或uncached，因此累计分类数
  // 只能小于等于lookup数，不能要求每个周期都严格相等。访问异常也可能只计lookup。
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (int'(retired_instruction_count_i) <= RETIRE_SLOT_COUNT)
      else $error("PMU observed more retired instructions than available retire slots");

      assert ((mcountinhibit_q & ~32'h0000_0005) == 32'b0)
      else $error("PMU stored an unsupported mcountinhibit bit");

      assert (!csr_read_select_o || pmu_csr_addr_implemented)
      else $error("PMU selected an unimplemented CSR address");

      assert ((icache_hit_count_q + icache_miss_count_q +
               icache_uncached_access_count_q) <= icache_lookup_count_q)
      else $error("I-cache classified more requests than it accepted");

      assert (!icache_event_i.lookup_response_is_cache_hit ||
              icache_event_i.lookup_response_present)
      else $error("I-cache marked a response as a hit while no response was present");

      assert (icache_refill_line_count_q <= icache_miss_count_q)
      else $error("I-cache completed more refill lines than cacheable misses");

      assert (icache_miss_response_count_q <= icache_miss_count_q)
      else $error("I-cache returned more miss responses than allocated misses");

      assert (icache_refill_transaction_count_q <= icache_miss_count_q)
      else $error("I-cache finished more refill transactions than allocated misses");

      assert (icache_refill_line_count_q <= icache_refill_transaction_count_q)
      else $error("I-cache installed more lines than completed refill transactions");

      assert (icache_refill_word_count_q >= (icache_refill_line_count_q * ICACHE_WORDS_PER_LINE))
      else $error("I-cache completed a refill line without receiving all words");

      assert (!(icache_event_i.lookup_occurred && icache_lookup_timer_active_q &&
                !icache_event_i.lookup_response_present))
      else $error("I-cache AMAT timer observed more than one outstanding lookup");

      assert (!icache_event_i.miss_occurred || icache_lookup_timer_active_q)
      else $error("I-cache AMAT timer observed a miss without an active lookup");

      assert (!icache_event_i.refill_transaction_completed_occurred || icache_refill_timer_active_q)
      else $error("I-cache refill timer observed completion without an active refill");
    end
  end
`endif

endmodule
