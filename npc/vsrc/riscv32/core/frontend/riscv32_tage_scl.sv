// 可选的缩放 TAGE/SC/loop 实现；结构和裁剪边界见BRANCH_V3_DESIGN.md。
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
  localparam int INDEX_BITS = $clog2(TAGGED_ENTRIES);
  localparam int HISTORY_BITS = TABLE_COUNT == 2 ? HISTORY_BITS_1 : HISTORY_BITS_2;
  localparam int LENGTHS[3] = '{HISTORY_BITS_0, HISTORY_BITS_1, HISTORY_BITS_2};
  localparam int ENTRY_BITS = 1 + TAG_BITS + 3 + 2;
  localparam int FOLD_BITS = INDEX_BITS + TAG_BITS + TAG_BITS - 1;
  typedef struct packed {
    logic [HISTORY_BITS-1:0]                history_before;
    logic [31:0]                            pc;
    logic [15:0]                            epoch;
    logic [TABLE_COUNT-1:0][INDEX_BITS-1:0] index;
    logic [TABLE_COUNT-1:0][TAG_BITS-1:0]   tag;
    logic [BASE_INDEX_BITS-1:0]             base_index;
    logic signed [2:0]                      provider;
    logic                                   alt,            raw, provider_weak, tage;
    logic [2:0][INDEX_BITS-1:0]             sc_index;
    logic signed [8:0]                      sum;
    logic [1:0]                             loop_index;
    logic                                   prediction;
  } context_t;
  initial begin
    if (BASE_ENTRIES < 16 || BASE_ENTRIES > 128 || (BASE_ENTRIES & (BASE_ENTRIES - 1)) != 0 ||
        TAGGED_ENTRIES < 8 || TAGGED_ENTRIES > 64 || (TAGGED_ENTRIES & (TAGGED_ENTRIES - 1)) != 0 ||
        TABLE_COUNT < 2 || TABLE_COUNT > 3 || TAG_BITS < 6 || TAG_BITS > 10 || HISTORY_BITS_0 < 1 ||
        HISTORY_BITS_0 >= HISTORY_BITS_1 || HISTORY_BITS > 32 ||
        (TABLE_COUNT == 3 && HISTORY_BITS_1 >= HISTORY_BITS_2) || $bits(
            context_t
        ) > 192)
      $fatal(1, "Unsupported scaled TAGE geometry or oversized context");
  end
  context_t query, training;
  assign training  = context_t'(training_context_i);
  assign context_o = 192'(query);

  // 1. 历史：解析版本每次训练推进；推测版本按采用的方向推进并保留解析副本。
  logic [HISTORY_BITS-1:0] history_q, resolved_history_q;
  logic [15:0] epoch_q;
  logic [INDEX_BITS-1:0] index_fold_q[TABLE_COUNT];
  logic [TAG_BITS-1:0] tag_fold_q[TABLE_COUNT];
  logic [TAG_BITS-2:0] tag_short_fold_q[TABLE_COUNT];
  logic train_event, history_advance_event, history_taken;
  logic [HISTORY_BITS-1:0] repaired_history;
  assign train_event = training_valid_i && !invalidate_i && training.epoch == epoch_q;
  assign history_advance_event = SPECULATIVE_HISTORY ?
      (lookup_handshake_i && lookup_conditional_i) : train_event;
  assign history_taken = SPECULATIVE_HISTORY ? lookup_taken_i : training_taken_i;
  assign repaired_history = train_event ?
      {training.history_before[HISTORY_BITS-2:0], training_taken_i} : resolved_history_q;

  // 仅恢复时重建折叠；正常查询与推进不串联完整历史折叠电路。
  function automatic logic [TAG_BITS-1:0] fold_recovery(input logic [HISTORY_BITS-1:0] value,
                                                        input int length, width);
    logic [TAG_BITS-1:0] folded;
    folded = '0;
    for (int i = 0; i < HISTORY_BITS; i++) begin
      if (i < length) folded[i%width] ^= value[i];
    end
    return folded;
  endfunction
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      history_q          <= '0;
      resolved_history_q <= '0;
      epoch_q            <= '0;
      for (int b = 0; b < TABLE_COUNT; b++) begin
        index_fold_q[b]     <= '0;
        tag_fold_q[b]       <= '0;
        tag_short_fold_q[b] <= '0;
      end
    end else if (invalidate_i) begin
      history_q          <= '0;
      resolved_history_q <= '0;
      epoch_q            <= epoch_q + 1'b1;
      for (int b = 0; b < TABLE_COUNT; b++) begin
        index_fold_q[b]     <= '0;
        tag_fold_q[b]       <= '0;
        tag_short_fold_q[b] <= '0;
      end
    end else begin
      if (train_event && SPECULATIVE_HISTORY)
        resolved_history_q <= {resolved_history_q[HISTORY_BITS-2:0], training_taken_i};
      if (SPECULATIVE_HISTORY && flush_i) begin
        history_q <= repaired_history;
        for (int b = 0; b < TABLE_COUNT; b++) begin
          index_fold_q[b] <= INDEX_BITS'(fold_recovery(repaired_history, LENGTHS[b], INDEX_BITS));
          tag_fold_q[b] <= fold_recovery(repaired_history, LENGTHS[b], TAG_BITS);
          tag_short_fold_q[b] <= (TAG_BITS - 1)'(fold_recovery(
              repaired_history, LENGTHS[b], TAG_BITS - 1
          ));
        end
      end else if (history_advance_event) begin
        history_q <= {history_q[HISTORY_BITS-2:0], history_taken};
        for (int b = 0; b < TABLE_COUNT; b++) begin
          index_fold_q[b] <= {index_fold_q[b][INDEX_BITS-2:0], index_fold_q[b][INDEX_BITS-1]} ^
              INDEX_BITS'(history_taken) ^
              (INDEX_BITS'(history_q[LENGTHS[b]-1]) << (LENGTHS[b] % INDEX_BITS));
          tag_fold_q[b] <= {tag_fold_q[b][TAG_BITS-2:0], tag_fold_q[b][TAG_BITS-1]} ^ TAG_BITS
              '(history_taken) ^ (TAG_BITS'(history_q[LENGTHS[b]-1]) << (LENGTHS[b] % TAG_BITS));
          tag_short_fold_q[b] <= {tag_short_fold_q[b][TAG_BITS-3:0], tag_short_fold_q[
                                  b][TAG_BITS-2]} ^ (TAG_BITS - 1)'(history_taken) ^
              ((TAG_BITS - 1)'(history_q[LENGTHS[b]-1]) << (LENGTHS[b] % (TAG_BITS - 1)));
        end
      end
    end
  end

  // 2. base/tagged并行读取，最长匹配与alternate按历史长度选择。
  logic [1:0] base_counter_array_q[BASE_ENTRIES];
  logic present_array_q[TABLE_COUNT][TAGGED_ENTRIES];
  logic [TAG_BITS-1:0] tag_array_q[TABLE_COUNT][TAGGED_ENTRIES];
  logic signed [2:0] counter_array_q[TABLE_COUNT][TAGGED_ENTRIES];
  logic [1:0] useful_array_q[TABLE_COUNT][TAGGED_ENTRIES];
  logic signed [3:0] alternate_select_q;
  logic signed [4:0] weight_array_q[3][TAGGED_ENTRIES];
  logic [4:0] threshold_q;
  logic loop_present_q[4], loop_direction_q[4];
  logic [31:0] loop_pc_q[4];
  logic [7:0] loop_trip_q[4], loop_current_q[4];
  logic [1:0] loop_confidence_q[4];
  logic [TABLE_COUNT-1:0][INDEX_BITS-1:0] lookup_index_array;
  logic [TABLE_COUNT-1:0][TAG_BITS-1:0] lookup_tag_array;
  logic [TABLE_COUNT-1:0] match_vector, provider_select_vector, alternate_select_vector;
  logic [TABLE_COUNT-1:0] direction_vector, weak_vector;
  logic base_direction;
  assign base_direction = base_counter_array_q[lookup_pc_i[BASE_INDEX_BITS+1:2]][1];
  for (genvar bank = 0; bank < TABLE_COUNT; bank++) begin : g_tagged_query
    logic signed [2:0] counter;
    logic longer_match, multiple_longer_matches;
    assign lookup_index_array[bank] = lookup_pc_i[INDEX_BITS+1:2] ^ index_fold_q[bank];
    assign lookup_tag_array[bank] = lookup_pc_i[TAG_BITS+1:2] ^ tag_fold_q[bank] ^
        {tag_short_fold_q[bank], 1'b0};
    assign match_vector[bank] = present_array_q[bank][lookup_index_array[bank]] &&
        tag_array_q[bank][lookup_index_array[bank]] == lookup_tag_array[bank];
    assign counter = counter_array_q[bank][lookup_index_array[bank]];
    assign direction_vector[bank] = !counter[2];
    assign weak_vector[bank] = counter == -1 || counter == 0;
    // 最长匹配没有更长命中；次长匹配恰有一个更长命中。
    always_comb begin
      longer_match = 1'b0;
      multiple_longer_matches = 1'b0;
      for (int other = bank + 1; other < TABLE_COUNT; other++) begin
        multiple_longer_matches |= longer_match && match_vector[other];
        longer_match |= match_vector[other];
      end
    end
    assign provider_select_vector[bank] = match_vector[bank] && !longer_match;
    assign alternate_select_vector[bank] = match_vector[bank] && longer_match &&
        !multiple_longer_matches;
  end

  // SC与TAGE并行：第三张表按两个方向读；公共部分和只计算一次。
  logic [INDEX_BITS-1:0] sc_index_array[3];
  logic signed [5:0] sc_weight_pair;
  logic signed [6:0] sc_common_sum;
  logic signed [7:0] sc_sum_array[2];
  logic [1:0] sc_prediction_vector;
  assign sc_index_array[0] = lookup_pc_i[INDEX_BITS+1:2];
  assign sc_index_array[1] = lookup_pc_i[INDEX_BITS+1:2] ^ INDEX_BITS'(history_q);
  assign sc_index_array[2] = lookup_pc_i[INDEX_BITS+1:2] ^ index_fold_q[TABLE_COUNT-1];
  assign sc_weight_pair = 6'(weight_array_q[0][sc_index_array[0]]) +
      6'(weight_array_q[1][sc_index_array[1]]);
  assign sc_common_sum = {sc_weight_pair, 1'b0} + 7'sd2;
  for (genvar direction = 0; direction < 2; direction++) begin : g_sc_direction
    logic signed [4:0] weight;
    logic signed [6:0] tail_sum;
    assign weight = weight_array_q[2][sc_index_array[2] ^ INDEX_BITS'(direction)];
    assign tail_sum = 7'(weight) * 7'sd2 + (direction == 0 ? -7'sd3 : 7'sd5);
    assign sc_sum_array[direction] = 8'(sc_common_sum) + 8'(tail_sum);
    // 原规则：强负和覆盖为NT，强正和覆盖为T，其余保持TAGE方向。
    assign sc_prediction_vector[direction] = direction == 0 ?
        sc_sum_array[direction] >= $signed({3'b0, threshold_q}) :
        sc_sum_array[direction] > -$signed({3'b0, threshold_q});
  end

  always_comb begin
    query                = '0;
    query.history_before = SPECULATIVE_HISTORY ? history_q : '0;
    query.pc             = lookup_pc_i;
    query.epoch          = epoch_q;
    query.base_index     = lookup_pc_i[BASE_INDEX_BITS+1:2];
    query.index          = lookup_index_array;
    query.tag            = lookup_tag_array;
    query.provider       = -1;
    for (int b = 0; b < TABLE_COUNT; b++) begin
      if (provider_select_vector[b])
        query.provider = 3'(b);
    end
    query.alt = (|(alternate_select_vector & direction_vector)) ||
        (!(|alternate_select_vector) && base_direction);
    query.raw = (|(provider_select_vector & direction_vector)) ||
        (!(|provider_select_vector) && base_direction);
    query.provider_weak = |(provider_select_vector & weak_vector);
    query.tage = query.provider_weak && alternate_select_q >= 0 ? query.alt : query.raw;
    query.sc_index[0] = sc_index_array[0];
    query.sc_index[1] = sc_index_array[1];
    query.sc_index[2] = sc_index_array[2] ^ INDEX_BITS'(query.tage);
    query.sum = 9'(sc_sum_array[query.tage]);
    query.prediction = SC_ENABLE ? sc_prediction_vector[query.tage] : query.tage;
    query.loop_index = lookup_pc_i[3:2];
    if (LOOP_ENABLE && loop_present_q[query.loop_index] &&
        loop_pc_q[query.loop_index] == lookup_pc_i && loop_confidence_q[query.loop_index] == 3 &&
        loop_trip_q[query.loop_index] != 0)
      query.prediction = ({1'b0, loop_current_q[query.loop_index]} + 9'd1) ==
          {1'b0, loop_trip_q[query.loop_index]} ? !loop_direction_q[query.loop_index] :
          loop_direction_q[query.loop_index];
    taken_o = query.prediction;
  end

  // 3. tagged/base训练：以快照定位，以当前counter更新；tag不匹配禁止训练新住户。
  function automatic int step(input int value, input bit up, input int low, high);
    if (up) return value == high ? value : value + 1;
    return value == low ? value : value - 1;
  endfunction
  logic signed [2:0] allocation_bank;
  always_comb begin
    allocation_bank = -1;
    for (int b = TABLE_COUNT - 1; b >= 0; b--) begin
      if (b > int'(training.provider) &&
          (!present_array_q[b][training.index[b]] || useful_array_q[b][training.index[b]] == 0))
        allocation_bank = b;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      alternate_select_q <= 0;
      for (int i = 0; i < BASE_ENTRIES; i++) base_counter_array_q[i] <= 1;
      for (int b = 0; b < TABLE_COUNT; b++) begin
        for (int i = 0; i < TAGGED_ENTRIES; i++) present_array_q[b][i] <= 0;
      end
    end else if (invalidate_i) begin
      for (int b = 0; b < TABLE_COUNT; b++) begin
        for (int i = 0; i < TAGGED_ENTRIES; i++) present_array_q[b][i] <= 0;
      end
    end else if (train_event) begin
      base_counter_array_q[training.base_index] <= 2'(step(
          int'(base_counter_array_q[training.base_index]), training_taken_i, 0, 3
      ));
      if (training.provider >= 0 && present_array_q[training.provider][
          training.index[training.provider]] && tag_array_q[training.provider][
          training.index[training.provider]] == training.tag[training.provider]) begin
        counter_array_q[training.provider][training.index[training.provider]] <= 3'(step(
            int'(counter_array_q[training.provider][training.index[training.provider]]),
            training_taken_i,
            -4,
            3
        ));
        if (training.raw != training.alt)
          useful_array_q[training.provider][training.index[training.provider]] <= 2'(step(
              int'(useful_array_q[training.provider][training.index[training.provider]]),
              training.raw == training_taken_i,
              0,
              3
          ));
        if (training.provider_weak && training.raw != training.alt)
          alternate_select_q <= 4'(step(
              int'(alternate_select_q), training.alt == training_taken_i, -8, 7
          ));
      end
      if (training.tage != training_taken_i) begin
        if (allocation_bank >= 0) begin
          present_array_q[allocation_bank][training.index[allocation_bank]] <= 1;
          tag_array_q[allocation_bank][training.index[allocation_bank]] <=
              training.tag[allocation_bank];
          counter_array_q[allocation_bank][training.index[allocation_bank]] <= training_taken_i ?
              0 : -1;
          useful_array_q[allocation_bank][training.index[allocation_bank]] <= 0;
        end else begin
          for (int b = 0; b < TABLE_COUNT; b++) begin
            if (b > int'(training.provider) && useful_array_q[b][training.index[b]] != 0)
              useful_array_q[b][training.index[b]] <= useful_array_q[b][training.index[b]] - 1'b1;
          end
        end
      end
    end
  end

  // 4. SC：有符号中心化求和、动态阈值、仅在错误或低margin时更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      threshold_q <= 8;
      for (int b = 0; b < 3; b++) begin
        for (int i = 0; i < TAGGED_ENTRIES; i++) weight_array_q[b][i] <= 0;
      end
    end else if (train_event && SC_ENABLE) begin
      if ((training.sum >= 0) != training_taken_i ||
          (training.sum < int'(threshold_q) && training.sum > -int'(threshold_q)))
        for (int b = 0; b < 3; b++)
        weight_array_q[b][training.sc_index[b]] <= 5'(step(
            int'(weight_array_q[b][training.sc_index[b]]), training_taken_i, -16, 15
        ));
      if ((training.sum >= 0) != training.tage)
        threshold_q <= 5'(step(int'(threshold_q), (training.sum >= 0) != training_taken_i, 1, 31));
    end
  end

  // 5. loop：PC身份、当前迭代与稳定trip；变长重学，溢出撤销可信度。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < 4; i++) loop_present_q[i] <= 0;
    end else if (invalidate_i) begin
      for (int i = 0; i < 4; i++) loop_present_q[i] <= 0;
    end else if (train_event && LOOP_ENABLE) begin
      if (!loop_present_q[training.loop_index] ||
          loop_pc_q[training.loop_index] != training.pc) begin
        loop_present_q[training.loop_index]    <= 1;
        loop_pc_q[training.loop_index]         <= training.pc;
        loop_current_q[training.loop_index]    <= 1;
        loop_trip_q[training.loop_index]       <= 0;
        loop_confidence_q[training.loop_index] <= 0;
        loop_direction_q[training.loop_index]  <= training_taken_i;
      end else if (training_taken_i == loop_direction_q[training.loop_index]) begin
        loop_current_q[training.loop_index] <= loop_current_q[training.loop_index] + 1'b1;
        if (loop_current_q[training.loop_index] == 255) begin
          loop_trip_q[training.loop_index]       <= 0;
          loop_confidence_q[training.loop_index] <= 0;
        end
      end else begin
        loop_confidence_q[training.loop_index] <=
            ({1'b0, loop_current_q[training.loop_index]} + 9'd1) ==
            {1'b0, loop_trip_q[training.loop_index]} ? 2'(step(
            int'(loop_confidence_q[training.loop_index]), 1, 0, 3
        )) : 0;
        loop_trip_q[training.loop_index] <= loop_current_q[training.loop_index] + 1'b1;
        loop_current_q[training.loop_index] <= 0;
      end
    end
  end
`ifdef BRANCH_V3_VERIFY
  // 逻辑状态展开：无效payload屏蔽；调试线不进入正常综合。
  int offset;
  always_comb begin
    state_o = '0;
    offset  = 0;
    for (int i = 0; i < BASE_ENTRIES; i++) begin
      state_o[offset+:2] = base_counter_array_q[i];
      offset += 2;
    end
    for (int b = 0; b < TABLE_COUNT; b++)
    for (int i = 0; i < TAGGED_ENTRIES; i++) begin
      state_o[offset+:ENTRY_BITS] = present_array_q[b][i] ?
          {1'b1, tag_array_q[b][i], counter_array_q[b][i], useful_array_q[b][i]} : ENTRY_BITS'(0);
      offset += ENTRY_BITS;
    end
    state_o[offset+:HISTORY_BITS] = history_q;
    offset += HISTORY_BITS;
    state_o[offset+:16] = epoch_q;
    offset += 16;
    state_o[offset+:4] = alternate_select_q;
    offset += 4;
    for (int b = 0; b < 3; b++)
    for (int i = 0; i < TAGGED_ENTRIES; i++) begin
      state_o[offset+:5] = weight_array_q[b][i];
      offset += 5;
    end
    state_o[offset+:5] = threshold_q;
    offset += 5;
    for (int i = 0; i < 4; i++) begin
      state_o[offset+:52] = loop_present_q[i] ?
          {1'b1, loop_pc_q[i], loop_current_q[i], loop_trip_q[i], loop_confidence_q[i],
           loop_direction_q[i]} : 52'b0;
      offset += 52;
    end
    for (int b = 0; b < TABLE_COUNT; b++) begin
      state_o[offset+:FOLD_BITS] = {index_fold_q[b], tag_fold_q[b], tag_short_fold_q[b]};
      offset += FOLD_BITS;
    end
    state_o[offset+:HISTORY_BITS] = resolved_history_q;
  end
`endif
endmodule
