// 条件方向预测：组合查表，携带查询快照，解析交付时训练；不增加查询或训练流水级。
module riscv32_bht
  import riscv32_pkg::*;
#(
    parameter int unsigned BHT_ENTRY_COUNT = riscv_config_pkg::BRANCH_HISTORY_ENTRY_COUNT,
    parameter int unsigned DIRECTION_POLICY = riscv_config_pkg::BRANCH_DIRECTION_POLICY,
    parameter int unsigned HISTORY_BITS = riscv_config_pkg::BRANCH_GLOBAL_HISTORY_BITS
) (
    input  logic               clk_i,
    input  logic               rst_ni,
    input  program_counter_t   lookup_pc_i,
    output logic [1:0]         lookup_counter_o,
    output direction_context_t lookup_context_o,
    input  program_counter_t   training_pc_i,
    input  logic               training_valid_i,
    input  logic               training_taken_i,
    input  direction_context_t training_context_i,
    input  logic               invalidate_i
);
  localparam int unsigned INDEX_BITS = $clog2(BHT_ENTRY_COUNT);
  localparam int unsigned OFFSET_BITS = $clog2(INSTRUCTION_BYTES);

  initial begin
    if (BHT_ENTRY_COUNT < 2 || (BHT_ENTRY_COUNT & (BHT_ENTRY_COUNT - 1)) != 0)
      $fatal(1, "direction counter count must be a power of two and at least two");
    if (DIRECTION_POLICY > 4 || HISTORY_BITS < 1 ||
        HISTORY_BITS != riscv_config_pkg::BRANCH_GLOBAL_HISTORY_BITS)
      $fatal(1, "invalid direction policy or history metadata width");
    if (DIRECTION_POLICY == 1 && HISTORY_BITS > INDEX_BITS)
      $fatal(1, "gshare history must fit its index");
    if (DIRECTION_POLICY == 2 && (BHT_ENTRY_COUNT < 8 || HISTORY_BITS > INDEX_BITS - 2))
      $fatal(1, "bi-mode requires three tables and history fitting a direction table index");
  end

  function automatic logic [1:0] update_counter(input logic [1:0] value, input logic taken);
    if (taken)
      return value == 2'b11 ? value : value + 2'b01;
    return value == 2'b00 ? value : value - 2'b01;
  endfunction

  // 1. 已解析历史：查询不写，普通flush不写；invalidate优先于训练。
  logic [HISTORY_BITS-1:0] history;
  if (DIRECTION_POLICY == 0) begin : g_no_history
    assign history = '0;
  end else begin : g_resolved_history
    logic [HISTORY_BITS-1:0] history_q;
    assign history = history_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni)
        history_q <= '0;
      else if (invalidate_i)
        history_q <= '0;
      else if (training_valid_i)
        history_q <= (history_q << 1) | HISTORY_BITS'(training_taken_i);
    end
  end

  if (DIRECTION_POLICY inside {3, 4}) begin : g_tage
    riscv32_tage #(
        .TABLE_ENTRIES     (BHT_ENTRY_COUNT),
        .PROTECT_ALTERNATE (DIRECTION_POLICY == 4)
    ) u_tage (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .lookup_pc_i        (lookup_pc_i),
        .lookup_history_i   (history),
        .lookup_counter_o   (lookup_counter_o),
        .lookup_context_o   (lookup_context_o),
        .training_pc_i      (training_pc_i),
        .training_context_i (training_context_i),
        .training_valid_i   (training_valid_i),
        .training_taken_i   (training_taken_i),
        .invalidate_i       (invalidate_i)
    );
  end else if (DIRECTION_POLICY != 2) begin : g_counter_table
    typedef logic [INDEX_BITS-1:0] index_t;
    logic [1:0] counter_array_q[BHT_ENTRY_COUNT];
    index_t lookup_index, training_index;
    logic [1:0] training_counter;

    // 2a. PC索引或PC异或历史：旧指令必须用它自己的查询历史训练。
    if (DIRECTION_POLICY == 0) begin : g_bimodal
      assign lookup_index = lookup_pc_i[OFFSET_BITS+:INDEX_BITS];
      assign training_index = training_pc_i[OFFSET_BITS+:INDEX_BITS];
      assign lookup_context_o = '0;
    end else begin : g_gshare
      assign lookup_index = lookup_pc_i[OFFSET_BITS+:INDEX_BITS] ^
                            (index_t'(history) << (INDEX_BITS - HISTORY_BITS));
      assign training_index = training_pc_i[OFFSET_BITS+:INDEX_BITS] ^
                              (index_t'(training_context_i.history) << (INDEX_BITS - HISTORY_BITS));
      always_comb begin
        lookup_context_o = '0;
        lookup_context_o.history = history;
      end
    end
    assign lookup_counter_o = counter_array_q[lookup_index];

    // 3a. 当前表值做饱和更新；连续同址训练自然读到前沿写入值。
    assign training_counter = update_counter(counter_array_q[training_index], training_taken_i);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned index = 0; index < BHT_ENTRY_COUNT; index++)
          counter_array_q[index] <= 2'b01;
      end else if (training_valid_i && !invalidate_i) begin
        counter_array_q[training_index] <= training_counter;
      end
    end
  end else begin : g_bimode
    localparam int unsigned CHOICE_ENTRIES = BHT_ENTRY_COUNT / 2;
    localparam int unsigned DIRECTION_ENTRIES = BHT_ENTRY_COUNT / 4;
    typedef logic [$clog2(CHOICE_ENTRIES)-1:0] choice_index_t;
    typedef logic [$clog2(DIRECTION_ENTRIES)-1:0] direction_index_t;
    logic [1:0] choice_array_q[CHOICE_ENTRIES];
    logic [1:0] direction_array_q[2][DIRECTION_ENTRIES];
    choice_index_t lookup_choice_index, training_choice_index;
    direction_index_t lookup_direction_index, training_direction_index;
    logic lookup_choice;
    logic [1:0] training_direction_counter, training_choice_counter;
    logic choice_update;

    // 2b. 两方向表与选择表并行读，再选择方向；快照保存实际选择，避免延迟训练串表。
    assign lookup_choice_index = choice_index_t'(lookup_pc_i >> OFFSET_BITS);
    assign lookup_direction_index = direction_index_t'(lookup_pc_i >> OFFSET_BITS) ^
                                    direction_index_t'(history);
    assign lookup_choice = choice_array_q[lookup_choice_index][1];
    assign lookup_counter_o = direction_array_q[lookup_choice][lookup_direction_index];
    always_comb begin
      lookup_context_o = '0;
      lookup_context_o.history = history;
      lookup_context_o.choice = lookup_choice;
      lookup_context_o.taken = lookup_counter_o[1];
    end

    // 3b. 只更新查询时选中的方向表；正确识别偏置例外时不改变选择表。
    assign training_choice_index = choice_index_t'(training_pc_i >> OFFSET_BITS);
    assign training_direction_index = direction_index_t'(training_pc_i >> OFFSET_BITS) ^
                                      direction_index_t'(training_context_i.history);
    assign training_direction_counter = update_counter(
        direction_array_q[training_context_i.choice][training_direction_index], training_taken_i);
    assign training_choice_counter = update_counter(choice_array_q[training_choice_index], training_taken_i);
    assign choice_update = (training_context_i.taken != training_taken_i) ||
                           (training_context_i.choice == training_taken_i);
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned index = 0; index < CHOICE_ENTRIES; index++)
          choice_array_q[index] <= 2'b01;
        for (int unsigned bank = 0; bank < 2; bank++)
          for (int unsigned index = 0; index < DIRECTION_ENTRIES; index++)
            direction_array_q[bank][index] <= bank == 0 ? 2'b01 : 2'b10;
      end else if (training_valid_i && !invalidate_i) begin
        direction_array_q[training_context_i.choice][training_direction_index] <= training_direction_counter;
        if (choice_update)
          choice_array_q[training_choice_index] <= training_choice_counter;
      end
    end
  end
endmodule
