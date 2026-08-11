module riscv32_pmu
  import riscv32_pkg::*;
#(
    parameter int unsigned RETIRE_SLOT_COUNT = 1
) (
    input logic clk_i,
    input logic rst_ni,

    input logic [$clog2(RETIRE_SLOT_COUNT + 1)-1:0] retired_instruction_count_i,

    // TODO(ICACHE-PMU-1): 在本TODO正下方增加
    // `input icache_event_t icache_event_i`。该结构体每个字段表示“本周期某事件发生”，
    // 不是累计值，也不是控制请求。PMU只在时钟沿把为1的字段累加到对应64-bit计数器。

    input  logic [    11:0] csr_read_addr_i,
    output logic            csr_read_select_o,
    output logic [XLEN-1:0] csr_read_data_o,

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

  assign retired_instruction_count_extended =
      {{(64-$bits(retired_instruction_count_i)){1'b0}}, retired_instruction_count_i};

  // mcountinhibit lets software stop selected counters. Only CY (bit 0) and IR
  // (bit 2) are implemented now. Other bits must always read as zero.
  logic [31:0] mcountinhibit_d;
  logic [31:0] mcountinhibit_q;

  // TODO(ICACHE-PMU-2): 在本TODO正下方声明I-cache性能计数器，每个计数器均使用_q/_d：
  // - icache_lookup_count：被I-cache接受的cacheable lookup数量；
  // - icache_hit_count：tag compare命中的lookup数量；
  // - icache_miss_count：分配miss状态的lookup数量；
  // - icache_refill_word_count：从下层成功接收的32-bit word数量；
  // - icache_refill_line_count：完整安装到tag/data array的line数量；
  // - icache_uncached_access_count：绕过cache但仍由其下层端口服务的请求数量；
  // - icache_stale_response_count：redirect后被epoch过滤的response数量。
  //
  // `lookup_count == hit_count + miss_count`只对cacheable且无access fault的lookup成立；
  // uncached和fault必须单独统计，不能为追求等式而重复计数。第一版可只通过仿真层读取
  // 这些寄存器，后续再决定是否映射到mhpmcounter3..31与mhpmevent3..31。

  // csr_read_select_o means "this address belongs to PMU". It is not a read
  // handshake and does not mean that the counter changed. riscv32_csr_file uses
  // it to choose PMU data instead of reporting an illegal CSR address.
  //
  // Write a unique case below the defaults. Each implemented case must assign
  // both select=1 and the corresponding data:
  //
  //   unique case (csr_read_addr_i)
  //     CSR_MCYCLE: begin
  //       csr_read_select_o = 1'b1;
  //       csr_read_data_o   = mcycle_q[31:0];
  //     end
  //     // CSR_MCYCLEH   returns mcycle_q[63:32]
  //     // CSR_MINSTRET  returns minstret_q[31:0]
  //     // CSR_MINSTRETH returns minstret_q[63:32]
  //     // CSR_MCOUNTINHIBIT returns mcountinhibit_q
  //     default: ;
  //   endcase
  //
  // Keep select low for every address not owned by PMU.
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

  // This block decides the values captured on the next rising edge. Begin with:
  //
  //   always_comb begin
  //     mcycle_d        = mcycle_q;
  //     minstret_d      = minstret_q;
  //     mcountinhibit_d = mcountinhibit_q;
  //
  // Then implement each state family independently.
  //
  // mcycle update:
  //   if writing CSR_MCYCLE, replace only [31:0];
  //   else if writing CSR_MCYCLEH, replace only [63:32];
  //   else if !mcountinhibit_q[0], use mcycle_q + 64'd1.
  // A CSR write has priority because software expects the written value to be the
  // new counter state, not the written value plus an implicit increment.
  //
  // minstret update uses a separate if/else-if chain:
  //   CSR_MINSTRET/MINSTRETH writes replace the selected half;
  //   otherwise, when !mcountinhibit_q[2], use
  //     minstret_q + {{padding{1'b0}}, retired_instruction_count_i};
  // You may simply rely on unsigned width extension when adding the input, but
  // explicit extension makes the intended 64-bit arithmetic easier to review.
  // A trap contributes zero because core already excludes trap-taking commits.
  //
  // mcountinhibit update:
  //   when writing CSR_MCOUNTINHIBIT, assign
  //     csr_write_data_i & 32'h0000_0005
  // so only CY and IR can become one. Close the always_comb after all three parts.
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

  // TODO(ICACHE-PMU-3): 在本TODO正下方为cache计数器写独立next-state组合块。
  // 每个`counter_d = counter_q + 64'(event_bit)`，其中event_bit只来自icache_event_i。
  // 不要把这些更新混入mcycle/minstret CSR写优先级块；两类状态生命周期不同，拆开后更
  // 容易加入mcountinhibit、溢出中断或事件选择器。若多个同类事件未来每周期可发生多次，
  // 把Boolean字段升级为count字段，而不是在PMU里猜测发射宽度。

  // TODO(ICACHE-PMU-4): 在本TODO正下方按状态族分别加入always_ff。
  // reset时所有cache计数器清零；正常周期捕获对应_d。继续遵循“相关寄存器靠近其next
  // 逻辑”的编码习惯，不要把全部PMU寄存器塞入一个远离定义的大always_ff。

  // TODO(ICACHE-PMU-5): 完成后用同一次I-cache定向测试核对计数关系。
  // cacheable且无access fault的lookup应满足lookup=hit+miss；refill line不能超过miss；
  // uncached和fault分别核对，不能为了凑等式重复计数。PMU只接收事件，不参与任何ready、
  // replacement或redirect逻辑。

  // These blocks contain no policy; they only capture the _d values chosen above.
  // Keep the register families separate so each state is adjacent to its purpose:
  //
  //   always_ff @(posedge clk_i or negedge rst_ni) begin
  //     if (!rst_ni) mcycle_q <= '0;
  //     else         mcycle_q <= mcycle_d;
  //   end
  //
  // Repeat the same structure for minstret_q and mcountinhibit_q. Resetting all
  // counters to zero gives deterministic software-visible behavior after reset.
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

endmodule
