// 可选的缩放 TAGE/SC/loop 实现；结构和裁剪边界见BRANCH_V3_DESIGN.md。
// 查询路径：历史索引 → 表并行读取 → provider/SC/Loop方向选择 → 组合输出。
// 训练反馈独立更新各表；本模块没有查询流水寄存器，响应保持由父预测器负责。
module riscv32_tage_scl #(
    parameter int unsigned BASE_ENTRIES = 32,
    parameter int unsigned TAGGED_ENTRIES = 16,
    parameter int unsigned TABLE_COUNT = 3,
    parameter int unsigned TAG_BITS = 8,
    parameter int unsigned HISTORY_BITS_0 = 3,
    parameter int unsigned HISTORY_BITS_1 = 7,
    parameter int unsigned HISTORY_BITS_2 = 16,
    parameter bit SPECULATIVE_HISTORY = 0,
    parameter bit SC_ENABLE = 0,
    parameter bit LOOP_ENABLE = 0
) (
    input  logic          clk_i,
    input  logic          rst_ni,
    input  logic [  31:0] lookup_pc_i,
    output logic          taken_o,
    output logic [ 191:0] context_o,
    input  logic          training_valid_i,
    input  logic          training_taken_i,
    input  logic [ 191:0] training_context_i,
`ifdef BRANCH_V3_VERIFY
    output logic [8191:0] state_o,
`endif
    input  logic          lookup_handshake_i,
    input  logic          lookup_conditional_i,
    input  logic          lookup_taken_i,
    input  logic          flush_i,
    input  logic          invalidate_i
);
  localparam int BASE_INDEX_BITS = $clog2(BASE_ENTRIES);
  localparam int TAGGED_INDEX_BITS = $clog2(TAGGED_ENTRIES);
  localparam int HISTORY_BITS = TABLE_COUNT == 2 ? HISTORY_BITS_1 : HISTORY_BITS_2;
  localparam int HISTORY_LENGTH_ARRAY[3] = '{HISTORY_BITS_0, HISTORY_BITS_1, HISTORY_BITS_2};
  localparam int ENTRY_BITS = 1 + TAG_BITS + 3 + 2;
  localparam int FOLD_BITS = TAGGED_INDEX_BITS + TAG_BITS + TAG_BITS - 1;
  typedef struct packed {
    logic [HISTORY_BITS-1:0]                     history_before;
    logic [31:0]                                pc;
    logic [15:0]                                epoch;
    logic [TABLE_COUNT-1:0][TAGGED_INDEX_BITS-1:0] tagged_index_vector;
    logic [TABLE_COUNT-1:0][TAG_BITS-1:0]          tagged_tag_vector;
    logic [BASE_INDEX_BITS-1:0]                  base_index;
    logic signed [2:0]                          provider_index;

    // 备用方向、最长匹配原始方向、弱provider及选择后的TAGE方向。
    logic alternate_taken, provider_taken, provider_weak, tage_taken;

    logic [2:0][TAGGED_INDEX_BITS-1:0] sc_index_vector;
    logic signed [8:0]                sc_sum;
    logic [1:0]                       loop_index;
    logic                             prediction;
  } context_t;
  initial begin
    if (BASE_ENTRIES < 16 || BASE_ENTRIES > 128 ||
        (BASE_ENTRIES & (BASE_ENTRIES - 1)) != 0 || TAGGED_ENTRIES < 8 || TAGGED_ENTRIES > 64 ||
        (TAGGED_ENTRIES & (TAGGED_ENTRIES - 1)) != 0 || TABLE_COUNT < 2 || TABLE_COUNT > 3 || TAG_BITS < 6 ||
        TAG_BITS > 10 || HISTORY_BITS_0 < 1 || HISTORY_BITS_0 >= HISTORY_BITS_1 || HISTORY_BITS > 32 ||
        (TABLE_COUNT == 3 && HISTORY_BITS_1 >= HISTORY_BITS_2) || $bits(context_t) > 192)
      $fatal(1, "Unsupported scaled TAGE geometry or oversized context");
  end
  context_t lookup_context, training_context;
  assign training_context = context_t'(training_context_i);
  assign context_o        = 192'(lookup_context);

  // 1. 历史：解析版本每次训练推进；推测版本按采用的方向推进并保留解析副本。
  logic [HISTORY_BITS-1:0] history_q, resolved_history_q;
  logic [                 15:0] epoch_q;
  logic [TAGGED_INDEX_BITS-1:0] index_fold_array_q    [TABLE_COUNT];
  logic [         TAG_BITS-1:0] tag_fold_array_q      [TABLE_COUNT];
  logic [         TAG_BITS-2:0] tag_short_fold_array_q[TABLE_COUNT];
  logic train_event, history_advance_event, history_taken;
  logic [HISTORY_BITS-1:0] repaired_history;
  assign train_event = training_valid_i && !invalidate_i && training_context.epoch == epoch_q;
  assign history_advance_event = SPECULATIVE_HISTORY ? (lookup_handshake_i && lookup_conditional_i) :
      train_event;
  assign history_taken = SPECULATIVE_HISTORY ? lookup_taken_i : training_taken_i;
  assign repaired_history = train_event ?
      {training_context.history_before[HISTORY_BITS-2:0], training_taken_i} : resolved_history_q;

  // 仅恢复时重建折叠；正常查询与推进不串联完整历史折叠电路。
  function automatic logic [TAG_BITS-1:0] fold_recovery(
      input logic [HISTORY_BITS-1:0] value, input int length, width);
    logic [TAG_BITS-1:0] folded;
    folded = '0;
    for (int entry_index = 0; entry_index < HISTORY_BITS; entry_index++) begin
      if (entry_index < length)
        folded[entry_index%width] ^= value[entry_index];
    end
    return folded;
  endfunction
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      history_q          <= '0;
      resolved_history_q <= '0;
      epoch_q            <= '0;
      for (int table_index = 0; table_index < TABLE_COUNT; table_index++) begin
        index_fold_array_q[table_index]     <= '0;
        tag_fold_array_q[table_index]       <= '0;
        tag_short_fold_array_q[table_index] <= '0;
      end
    end else if (invalidate_i) begin
      history_q          <= '0;
      resolved_history_q <= '0;
      epoch_q            <= epoch_q + 1'b1;
      for (int table_index = 0; table_index < TABLE_COUNT; table_index++) begin
        index_fold_array_q[table_index]     <= '0;
        tag_fold_array_q[table_index]       <= '0;
        tag_short_fold_array_q[table_index] <= '0;
      end
    end else begin
      if (train_event && SPECULATIVE_HISTORY)
        resolved_history_q <= {resolved_history_q[HISTORY_BITS-2:0], training_taken_i};
      if (SPECULATIVE_HISTORY && flush_i) begin
        history_q <= repaired_history;
        for (int table_index = 0; table_index < TABLE_COUNT; table_index++) begin
          index_fold_array_q[table_index] <= TAGGED_INDEX_BITS'(fold_recovery(
              repaired_history, HISTORY_LENGTH_ARRAY[table_index], TAGGED_INDEX_BITS
          ));
          tag_fold_array_q[table_index] <= fold_recovery(
              repaired_history, HISTORY_LENGTH_ARRAY[table_index], TAG_BITS
          );
          tag_short_fold_array_q[table_index] <= (TAG_BITS - 1)'(fold_recovery(
              repaired_history, HISTORY_LENGTH_ARRAY[table_index], TAG_BITS - 1
          ));
        end
      end else if (history_advance_event) begin
        history_q <= {history_q[HISTORY_BITS-2:0], history_taken};
        for (int table_index = 0; table_index < TABLE_COUNT; table_index++) begin
          index_fold_array_q[table_index] <=
              {index_fold_array_q[table_index][TAGGED_INDEX_BITS-2:0],
               index_fold_array_q[table_index][TAGGED_INDEX_BITS-1]} ^
              TAGGED_INDEX_BITS'(history_taken) ^
              (TAGGED_INDEX_BITS'(history_q[HISTORY_LENGTH_ARRAY[table_index]-1]) <<
               (HISTORY_LENGTH_ARRAY[table_index] % TAGGED_INDEX_BITS));
          tag_fold_array_q[table_index] <=
              {tag_fold_array_q[table_index][TAG_BITS-2:0],
               tag_fold_array_q[table_index][TAG_BITS-1]} ^
              TAG_BITS'(history_taken) ^
              (TAG_BITS'(history_q[HISTORY_LENGTH_ARRAY[table_index]-1]) <<
               (HISTORY_LENGTH_ARRAY[table_index] % TAG_BITS));
          tag_short_fold_array_q[table_index] <=
              {tag_short_fold_array_q[table_index][TAG_BITS-3:0],
               tag_short_fold_array_q[table_index][TAG_BITS-2]} ^
              (TAG_BITS - 1)'(history_taken) ^
              ((TAG_BITS - 1)'(history_q[HISTORY_LENGTH_ARRAY[table_index]-1]) <<
               (HISTORY_LENGTH_ARRAY[table_index] % (TAG_BITS - 1)));
        end
      end
    end
  end

  // 2. base/tagged并行读取，最长匹配与alternate按历史长度选择。
  logic        [         1:0] base_counter_array_q[BASE_ENTRIES];
  logic                       present_array_q     [ TABLE_COUNT] [TAGGED_ENTRIES];
  logic        [TAG_BITS-1:0] tag_array_q         [ TABLE_COUNT] [TAGGED_ENTRIES];
  logic signed [         2:0] counter_array_q     [ TABLE_COUNT] [TAGGED_ENTRIES];
  logic        [         1:0] useful_array_q      [ TABLE_COUNT] [TAGGED_ENTRIES];
  logic signed [         3:0] alternate_select_q;
  logic signed [         4:0] weight_array_q      [           3] [TAGGED_ENTRIES];
  // SC权重与阈值在解析反馈时更新；查询只读。
  logic        [         4:0] threshold_q;
  // Loop表保存已解析迭代；invalidate仅清存在位，无效载荷不复位。
  logic loop_present_array_q[4], loop_direction_array_q[4];
  logic [31:0] loop_pc_array_q[4];
  logic [7:0] loop_trip_count_array_q[4], loop_iteration_count_array_q[4];
  logic [1:0] loop_confidence_array_q[4];
  logic [TABLE_COUNT-1:0][TAGGED_INDEX_BITS-1:0] lookup_index_vector;
  logic [TABLE_COUNT-1:0][         TAG_BITS-1:0] lookup_tag_vector;
  logic [TABLE_COUNT-1:0] match_vector, provider_select_vector, alternate_select_vector;
  logic [TABLE_COUNT-1:0] direction_vector, weak_vector;
  logic base_direction;
  assign base_direction = base_counter_array_q[lookup_pc_i[BASE_INDEX_BITS+1:2]][1];
  for (genvar bank = 0; bank < TABLE_COUNT; bank++) begin : g_tagged_query
    logic signed [2:0] counter;
    logic longer_match, multiple_longer_matches;
    assign lookup_index_vector[bank] = lookup_pc_i[TAGGED_INDEX_BITS+1:2] ^ index_fold_array_q[bank];
    assign lookup_tag_vector[bank] = lookup_pc_i[TAG_BITS+1:2] ^ tag_fold_array_q[bank] ^
        {tag_short_fold_array_q[bank], 1'b0};
    assign match_vector[bank] = present_array_q[bank][lookup_index_vector[bank]] &&
        tag_array_q[bank][lookup_index_vector[bank]] == lookup_tag_vector[bank];
    assign counter = counter_array_q[bank][lookup_index_vector[bank]];
    assign direction_vector[bank] = !counter[2];
    assign weak_vector[bank] = counter == -1 || counter == 0;
    // 最长匹配没有更长命中；次长匹配恰有一个更长命中。
    always_comb begin
      longer_match            = 1'b0;
      multiple_longer_matches = 1'b0;
      for (int other = bank + 1; other < TABLE_COUNT; other++) begin
        multiple_longer_matches |= longer_match && match_vector[other];
        longer_match |= match_vector[other];
      end
    end
    assign provider_select_vector[bank]  = match_vector[bank] && !longer_match;
    assign alternate_select_vector[bank] = match_vector[bank] && longer_match && !multiple_longer_matches;
  end

  // SC与TAGE并行：第三张表按两个方向读；公共部分和只计算一次。
  logic        [TAGGED_INDEX_BITS-1:0] sc_index_array       [3];
  logic signed [                  5:0] sc_weight_pair;
  logic signed [                  6:0] sc_common_sum;
  logic signed [                  7:0] sc_sum_array         [2];
  logic        [                  1:0] sc_prediction_vector;
  assign sc_index_array[0] = lookup_pc_i[TAGGED_INDEX_BITS+1:2];
  assign sc_index_array[1] = lookup_pc_i[TAGGED_INDEX_BITS+1:2] ^ TAGGED_INDEX_BITS'(history_q);
  assign sc_index_array[2] = lookup_pc_i[TAGGED_INDEX_BITS+1:2] ^ index_fold_array_q[TABLE_COUNT-1];
  assign sc_weight_pair = 6'(weight_array_q[0][sc_index_array[0]]) + 6'(weight_array_q[1][sc_index_array[1]]);
  assign sc_common_sum = {sc_weight_pair, 1'b0} + 7'sd2;
  for (genvar direction = 0; direction < 2; direction++) begin : g_sc_direction
    logic signed [4:0] weight;
    logic signed [6:0] tail_sum;
    assign weight = weight_array_q[2][sc_index_array[2]^TAGGED_INDEX_BITS'(direction)];
    assign tail_sum = 7'(weight) * 7'sd2 + (direction == 0 ? -7'sd3 : 7'sd5);
    assign sc_sum_array[direction] = 8'(sc_common_sum) + 8'(tail_sum);
    // 原规则：强负和覆盖为NT，强正和覆盖为T，其余保持TAGE方向。
    assign sc_prediction_vector[direction] = direction == 0 ?
        sc_sum_array[direction] >= $signed({3'b0, threshold_q}) :
        sc_sum_array[direction] > -$signed({3'b0, threshold_q});
  end

  // 查询汇合：provider/alternate → SC方向选择 → Loop覆盖 → 查询快照。
  always_comb begin
    lookup_context                     = '0;
    lookup_context.history_before      = SPECULATIVE_HISTORY ? history_q : '0;
    lookup_context.pc                  = lookup_pc_i;
    lookup_context.epoch               = epoch_q;
    lookup_context.base_index          = lookup_pc_i[BASE_INDEX_BITS+1:2];
    lookup_context.tagged_index_vector = lookup_index_vector;
    lookup_context.tagged_tag_vector   = lookup_tag_vector;
    lookup_context.provider_index      = -1;
    for (int table_index = 0; table_index < TABLE_COUNT; table_index++) begin
      if (provider_select_vector[table_index])
        lookup_context.provider_index = 3'(table_index);
    end
    lookup_context.alternate_taken = (|(alternate_select_vector & direction_vector)) ||
        (!(|alternate_select_vector) && base_direction);
    lookup_context.provider_taken = (|(provider_select_vector & direction_vector)) ||
        (!(|provider_select_vector) && base_direction);
    lookup_context.provider_weak = |(provider_select_vector & weak_vector);
    lookup_context.tage_taken = lookup_context.provider_weak && alternate_select_q >= 0 ?
        lookup_context.alternate_taken : lookup_context.provider_taken;
    lookup_context.sc_index_vector[0] = sc_index_array[0];
    lookup_context.sc_index_vector[1] = sc_index_array[1];
    lookup_context.sc_index_vector[2] = sc_index_array[2] ^ TAGGED_INDEX_BITS'(lookup_context.tage_taken);
    lookup_context.sc_sum = 9'(sc_sum_array[lookup_context.tage_taken]);
    lookup_context.prediction = SC_ENABLE ? sc_prediction_vector[lookup_context.tage_taken] :
        lookup_context.tage_taken;
    lookup_context.loop_index = lookup_pc_i[3:2];
    if (LOOP_ENABLE && loop_present_array_q[lookup_context.loop_index] &&
        loop_pc_array_q[lookup_context.loop_index] == lookup_pc_i && loop_confidence_array_q[
        lookup_context.loop_index] == 3 && loop_trip_count_array_q[lookup_context.loop_index] != 0)
      lookup_context.prediction = ({1'b0, loop_iteration_count_array_q[lookup_context.loop_index]} + 9'd1) ==
          {1'b0, loop_trip_count_array_q[lookup_context.loop_index]} ? !loop_direction_array_q[
          lookup_context.loop_index] : loop_direction_array_q[lookup_context.loop_index];
    taken_o = lookup_context.prediction;
  end

  // 3. tagged/base训练：以快照定位，以当前counter更新；tag不匹配禁止训练新住户。
  function automatic int saturating_step(input int value, input bit up, input int low, high);
    if (up)
      return value == high ? value : value + 1;
    return value == low ? value : value - 1;
  endfunction
  logic signed [2:0] allocation_table_index;
  always_comb begin
    allocation_table_index = -1;
    for (int table_index = TABLE_COUNT - 1; table_index >= 0; table_index--) begin
      if (table_index > int'(training_context.provider_index) &&
          (!present_array_q[table_index][training_context.tagged_index_vector[table_index]] ||
           useful_array_q[table_index][training_context.tagged_index_vector[table_index]] == 0))
        allocation_table_index = table_index;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      alternate_select_q <= 0;
      for (int entry_index = 0; entry_index < BASE_ENTRIES; entry_index++)
        base_counter_array_q[entry_index] <= 1;
      for (int table_index = 0; table_index < TABLE_COUNT; table_index++) begin
        for (int entry_index = 0; entry_index < TAGGED_ENTRIES; entry_index++)
          present_array_q[table_index][entry_index] <= 0;
      end
    end else if (invalidate_i) begin
      for (int table_index = 0; table_index < TABLE_COUNT; table_index++) begin
        for (int entry_index = 0; entry_index < TAGGED_ENTRIES; entry_index++)
          present_array_q[table_index][entry_index] <= 0;
      end
    end else if (train_event) begin
      base_counter_array_q[training_context.base_index] <= 2'(saturating_step(
          int'(base_counter_array_q[training_context.base_index]), training_taken_i, 0, 3
      ));
      if (training_context.provider_index >= 0 && present_array_q[training_context.provider_index][
          training_context.tagged_index_vector[training_context.provider_index]] &&
          tag_array_q[training_context.provider_index][
          training_context.tagged_index_vector[training_context.provider_index]] ==
          training_context.tagged_tag_vector[training_context.provider_index]) begin
        counter_array_q[training_context.provider_index][
            training_context.tagged_index_vector[training_context.provider_index]] <= 3'(saturating_step(
            int'(counter_array_q[training_context.provider_index][
                 training_context.tagged_index_vector[training_context.provider_index]]),
            training_taken_i,
            -4,
            3
        ));
        if (training_context.provider_taken != training_context.alternate_taken)
          useful_array_q[training_context.provider_index][
              training_context.tagged_index_vector[training_context.provider_index]] <= 2'(saturating_step(
              int'(useful_array_q[training_context.provider_index][
                   training_context.tagged_index_vector[training_context.provider_index]]),
              training_context.provider_taken == training_taken_i,
              0,
              3
          ));
        if (training_context.provider_weak &&
            training_context.provider_taken != training_context.alternate_taken)
          alternate_select_q <= 4'(saturating_step(
              int'(alternate_select_q), training_context.alternate_taken == training_taken_i, -8, 7
          ));
      end
      if (training_context.tage_taken != training_taken_i) begin
        if (allocation_table_index >= 0) begin
          present_array_q[allocation_table_index][
              training_context.tagged_index_vector[allocation_table_index]] <= 1;
          tag_array_q[allocation_table_index][training_context.tagged_index_vector[allocation_table_index]] <=
              training_context.tagged_tag_vector[allocation_table_index];
          counter_array_q[allocation_table_index][
              training_context.tagged_index_vector[allocation_table_index]] <= training_taken_i ? 0 : -1;
          useful_array_q[allocation_table_index][training_context.tagged_index_vector[allocation_table_index]]
              <= 0;
        end else begin
          for (int table_index = 0; table_index < TABLE_COUNT; table_index++) begin
            if (table_index > int'(training_context.provider_index) &&
                useful_array_q[table_index][training_context.tagged_index_vector[table_index]] != 0)
              useful_array_q[table_index][training_context.tagged_index_vector[table_index]] <=
                  useful_array_q[table_index][training_context.tagged_index_vector[table_index]] - 1'b1;
          end
        end
      end
    end
  end

  // 4. SC：有符号中心化求和、动态阈值、仅在错误或低margin时更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      threshold_q <= 8;
      for (int table_index = 0; table_index < 3; table_index++) begin
        for (int entry_index = 0; entry_index < TAGGED_ENTRIES; entry_index++)
          weight_array_q[table_index][entry_index] <= 0;
      end
    end else if (train_event && SC_ENABLE) begin
      if ((training_context.sc_sum >= 0) != training_taken_i ||
          (training_context.sc_sum < int'(threshold_q) && training_context.sc_sum > -int'(threshold_q)))
        for (int table_index = 0; table_index < 3; table_index++)
          weight_array_q[table_index][training_context.sc_index_vector[table_index]] <= 5'(saturating_step(
              int'(weight_array_q[table_index][training_context.sc_index_vector[table_index]]),
              training_taken_i,
              -16,
              15
          ));
      if ((training_context.sc_sum >= 0) != training_context.tage_taken)
        threshold_q <= 5'(saturating_step(
            int'(threshold_q), (training_context.sc_sum >= 0) != training_taken_i, 1, 31
        ));
    end
  end

  // 5. loop：PC身份、当前迭代与稳定trip；变长重学，溢出撤销可信度。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int entry_index = 0; entry_index < 4; entry_index++)
        loop_present_array_q[entry_index] <= 0;
    end else if (invalidate_i) begin
      for (int entry_index = 0; entry_index < 4; entry_index++)
        loop_present_array_q[entry_index] <= 0;
    end else if (train_event && LOOP_ENABLE) begin
      if (!loop_present_array_q[training_context.loop_index] ||
          loop_pc_array_q[training_context.loop_index] != training_context.pc) begin
        loop_present_array_q[training_context.loop_index]         <= 1;
        loop_pc_array_q[training_context.loop_index]              <= training_context.pc;
        loop_iteration_count_array_q[training_context.loop_index] <= 1;
        loop_trip_count_array_q[training_context.loop_index]      <= 0;
        loop_confidence_array_q[training_context.loop_index]      <= 0;
        loop_direction_array_q[training_context.loop_index]       <= training_taken_i;
      end else if (training_taken_i == loop_direction_array_q[training_context.loop_index]) begin
        loop_iteration_count_array_q[training_context.loop_index] <=
            loop_iteration_count_array_q[training_context.loop_index] + 1'b1;
        if (loop_iteration_count_array_q[training_context.loop_index] == 255) begin
          loop_trip_count_array_q[training_context.loop_index] <= 0;
          loop_confidence_array_q[training_context.loop_index] <= 0;
        end
      end else begin
        loop_confidence_array_q[training_context.loop_index] <=
            ({1'b0, loop_iteration_count_array_q[training_context.loop_index]} + 9'd1) ==
            {1'b0, loop_trip_count_array_q[training_context.loop_index]} ? 2'(saturating_step(
            int'(loop_confidence_array_q[training_context.loop_index]), 1, 0, 3
        )) : 0;
        loop_trip_count_array_q[training_context.loop_index] <=
            loop_iteration_count_array_q[training_context.loop_index] + 1'b1;
        loop_iteration_count_array_q[training_context.loop_index] <= 0;
      end
    end
  end
`ifdef BRANCH_V3_VERIFY
  // 逻辑状态展开：无效payload屏蔽；调试线不进入正常综合。
  int state_bit_offset;
  always_comb begin
    state_o          = '0;
    state_bit_offset = 0;
    for (int entry_index = 0; entry_index < BASE_ENTRIES; entry_index++) begin
      state_o[state_bit_offset+:2] = base_counter_array_q[entry_index];
      state_bit_offset += 2;
    end
    for (int table_index = 0; table_index < TABLE_COUNT; table_index++)
      for (int entry_index = 0; entry_index < TAGGED_ENTRIES; entry_index++) begin
        state_o[state_bit_offset+:ENTRY_BITS] = present_array_q[table_index][entry_index] ?
            {1'b1, tag_array_q[table_index][entry_index], counter_array_q[table_index][entry_index],
             useful_array_q[table_index][entry_index]} : ENTRY_BITS'(0);
        state_bit_offset += ENTRY_BITS;
      end
    state_o[state_bit_offset+:HISTORY_BITS] = history_q;
    state_bit_offset += HISTORY_BITS;
    state_o[state_bit_offset+:16] = epoch_q;
    state_bit_offset += 16;
    state_o[state_bit_offset+:4] = alternate_select_q;
    state_bit_offset += 4;
    for (int table_index = 0; table_index < 3; table_index++)
      for (int entry_index = 0; entry_index < TAGGED_ENTRIES; entry_index++) begin
        state_o[state_bit_offset+:5] = weight_array_q[table_index][entry_index];
        state_bit_offset += 5;
      end
    state_o[state_bit_offset+:5] = threshold_q;
    state_bit_offset += 5;
    for (int entry_index = 0; entry_index < 4; entry_index++) begin
      state_o[state_bit_offset+:52] = loop_present_array_q[entry_index] ?
          {1'b1, loop_pc_array_q[entry_index], loop_iteration_count_array_q[entry_index],
           loop_trip_count_array_q[entry_index], loop_confidence_array_q[entry_index],
           loop_direction_array_q[entry_index]} : 52'b0;
      state_bit_offset += 52;
    end
    for (int table_index = 0; table_index < TABLE_COUNT; table_index++) begin
      state_o[state_bit_offset+:FOLD_BITS] = {
        index_fold_array_q[table_index], tag_fold_array_q[table_index], tag_short_fold_array_q[table_index]
      };
      state_bit_offset += FOLD_BITS;
    end
    state_o[state_bit_offset+:HISTORY_BITS] = resolved_history_q;
  end
`endif
endmodule
