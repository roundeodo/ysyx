// 小型TAGE：并行查基础表和三张历史表，直接送入既有预测响应寄存器。
module riscv32_tage
  import riscv32_pkg::*;
#(
    parameter int unsigned TABLE_ENTRIES = riscv_config_pkg::BRANCH_HISTORY_ENTRY_COUNT,
    parameter bit PROTECT_ALTERNATE = (riscv_config_pkg::BRANCH_DIRECTION_POLICY == 4)
) (
    input  logic               clk_i,
    input  logic               rst_ni,
    input  program_counter_t   lookup_pc_i,
    input  logic [15:0]         lookup_history_i,
    output logic [1:0]          lookup_counter_o,
    output direction_context_t lookup_context_o,
    input  program_counter_t   training_pc_i,
    input  direction_context_t training_context_i,
    input  logic               training_valid_i,
    input  logic               training_taken_i,
    input  logic               invalidate_i
);
  localparam int unsigned INDEX_BITS = $clog2(TABLE_ENTRIES);
  localparam int unsigned BANK_COUNT = 3;
  typedef logic [INDEX_BITS-1:0] index_t;
  typedef logic [7:0] tag_t;
  typedef struct packed {
    logic       present;
    tag_t       tag;
    logic [2:0] counter;
    logic       useful;
  } entry_t;

  initial begin
    if (!(TABLE_ENTRIES inside {8, 16, 32}) || riscv_config_pkg::BRANCH_GLOBAL_HISTORY_BITS != 16)
      $fatal(1, "small TAGE requires 8/16/32 entries per table and 16-bit history");
  end

  // 1. PC/历史组合哈希：长度由generate常量决定，没有折叠历史寄存器。
  function automatic logic [15:0] fold_history(
      input logic [15:0] history, input int unsigned width, input int unsigned length);
    logic [15:0] folded;
    folded = '0;
    for (int unsigned bit_index = 0; bit_index < length; bit_index++)
      folded[bit_index % width] ^= history[bit_index];
    return folded;
  endfunction

  function automatic tag_t history_tag(
      input program_counter_t pc, input logic [15:0] history, input int unsigned length);
    return tag_t'((pc >> 2) ^ (pc >> 10) ^ fold_history(history, 8, length) ^
                  (fold_history(history, 7, length) << 1));
  endfunction

  index_t lookup_base_index, training_base_index;
  index_t lookup_index_array[BANK_COUNT], training_index_array[BANK_COUNT];
  tag_t lookup_tag_array[BANK_COUNT], training_tag_array[BANK_COUNT];
  entry_t entry_array_q[BANK_COUNT][TABLE_ENTRIES];
  logic [1:0] base_counter_array_q[TABLE_ENTRIES];
  logic [BANK_COUNT-1:0] lookup_match_vector, training_match_vector;

  assign lookup_base_index   = index_t'(lookup_pc_i >> 2);
  assign training_base_index = index_t'(training_pc_i >> 2);
  for (genvar bank = 0; bank < BANK_COUNT; bank++) begin : g_hash
    localparam int unsigned HISTORY_BITS = 4 << bank;
    assign lookup_index_array[bank] =
        lookup_base_index ^ index_t'(fold_history(lookup_history_i, INDEX_BITS, HISTORY_BITS));
    assign training_index_array[bank] =
        training_base_index ^ index_t'(fold_history(training_context_i.history, INDEX_BITS, HISTORY_BITS));
    assign lookup_tag_array[bank] = history_tag(lookup_pc_i, lookup_history_i, HISTORY_BITS);
    assign training_tag_array[bank] = history_tag(training_pc_i, training_context_i.history, HISTORY_BITS);
    assign lookup_match_vector[bank] =
        entry_array_q[bank][lookup_index_array[bank]].present &&
        entry_array_q[bank][lookup_index_array[bank]].tag == lookup_tag_array[bank];
    assign training_match_vector[bank] =
        entry_array_q[bank][training_index_array[bank]].present &&
        entry_array_q[bank][training_index_array[bank]].tag == training_tag_array[bank];
  end

  // 2. 最长匹配选择：完整查询快照随指令走，反压由外层响应寄存器负责。
  always_comb begin
    lookup_counter_o = base_counter_array_q[lookup_base_index];
    lookup_context_o = '0;
    lookup_context_o.history = lookup_history_i;
    lookup_context_o.alternate_taken = lookup_counter_o[1];
    for (int unsigned bank = 0; bank < BANK_COUNT; bank++) begin
      if (lookup_match_vector[bank]) begin
        lookup_context_o.alternate_provider = lookup_context_o.provider;
        lookup_context_o.alternate_taken = lookup_counter_o[1];
        lookup_context_o.provider = 2'(bank + 1);
        lookup_counter_o = entry_array_q[bank][lookup_index_array[bank]].counter[2:1];
      end
    end
    lookup_context_o.taken = lookup_counter_o[1];
    // 标准策略不需要备用提供者编号，保持为常量以删除对应载荷状态。
    if (!PROTECT_ALTERNATE)
      lookup_context_o.alternate_provider = '0;
  end

  // 3. 分配反馈：仅错误预测分配一项，失败则老化候选项，不阻塞取指。
  logic allocation_requested, allocation_present;
  logic [1:0] allocation_bank;
  assign allocation_requested = training_context_i.taken != training_taken_i;
  always_comb begin
    allocation_present = 1'b0;
    allocation_bank = '0;
    for (int unsigned bank = 0; bank < BANK_COUNT; bank++) begin
      if (!allocation_present && (bank >= int'(training_context_i.provider)) &&
          (!entry_array_q[bank][training_index_array[bank]].present ||
           !entry_array_q[bank][training_index_array[bank]].useful)) begin
        allocation_present = 1'b1;
        allocation_bank = 2'(bank);
      end
    end
  end

  // 4. 基础表独立写口：使用当前计数器，连续同址训练不丢失更新。
  function automatic logic [1:0] update_base(input logic [1:0] value, input logic taken);
    if (taken)
      return value == 2'b11 ? value : value + 2'b01;
    return value == 2'b00 ? value : value - 2'b01;
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned index = 0; index < TABLE_ENTRIES; index++)
        base_counter_array_q[index] <= 2'b01;
    end else if (training_valid_i && !invalidate_i) begin
      base_counter_array_q[training_base_index] <=
          update_base(base_counter_array_q[training_base_index], training_taken_i);
    end
  end

  // 5. 各历史表只写训练索引：标签检查保护延迟provider，失效优先于训练。
  function automatic logic [2:0] update_tagged(input logic [2:0] value, input logic taken);
    if (taken)
      return value == 3'b111 ? value : value + 3'b001;
    return value == 3'b000 ? value : value - 3'b001;
  endfunction

  for (genvar bank = 0; bank < BANK_COUNT; bank++) begin : g_update
    entry_t training_entry;
    always_comb begin
      training_entry = entry_array_q[bank][training_index_array[bank]];
      if ((training_context_i.provider == 2'(bank + 1)) && training_match_vector[bank]) begin
        training_entry.counter = update_tagged(training_entry.counter, training_taken_i);
        if (training_context_i.taken != training_context_i.alternate_taken)
          training_entry.useful = training_context_i.taken == training_taken_i;
      end
      if (PROTECT_ALTERNATE && training_match_vector[bank] &&
          (training_context_i.alternate_provider == 2'(bank + 1)) &&
          (training_context_i.taken != training_taken_i) &&
          (training_context_i.alternate_taken == training_taken_i))
        training_entry.useful = 1'b1;
      if (allocation_requested && bank >= int'(training_context_i.provider)) begin
        if (allocation_present && allocation_bank == 2'(bank)) begin
          training_entry.present = 1'b1;
          training_entry.tag = training_tag_array[bank];
          training_entry.counter = training_taken_i ? 3'b100 : 3'b011;
          training_entry.useful = 1'b0;
        end else if (!allocation_present) begin
          training_entry.useful = 1'b0;
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned index = 0; index < TABLE_ENTRIES; index++)
          entry_array_q[bank][index] <= '0;
      end else if (invalidate_i) begin
        for (int unsigned index = 0; index < TABLE_ENTRIES; index++)
          entry_array_q[bank][index].present <= 1'b0;
      end else if (training_valid_i) begin
        entry_array_q[bank][training_index_array[bank]] <= training_entry;
      end
    end
  end
endmodule
