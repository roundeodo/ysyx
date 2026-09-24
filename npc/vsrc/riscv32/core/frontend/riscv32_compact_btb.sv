// 完整 tag，按路固定目标位宽；查询拼接 PC 高位，不新增流水级。
module riscv32_compact_btb
  import riscv32_pkg::*;
#(
    parameter int unsigned BTB_ENTRY_COUNT = 16,
    parameter int unsigned BTB_WAY_COUNT = 2,
    parameter int unsigned BTB_POLICY = 0,
    parameter logic [31:0] BTB_WAY_TARGET_BITS = 32'h00001010
) (
    input logic clk_i,
    input logic rst_ni,
    input program_counter_t lookup_pc_i,
    output logic lookup_target_present_o,
    output program_counter_t lookup_target_pc_o,
    output branch_target_kind_e lookup_target_kind_o,
    input program_counter_t training_pc_i,
    input program_counter_t training_target_pc_i,
    input branch_target_kind_e training_kind_i,
    input logic training_valid_i,
    input logic training_taken_i,
    input logic invalidate_i
);
  localparam int unsigned SET_COUNT = BTB_ENTRY_COUNT / BTB_WAY_COUNT;
  localparam int unsigned OFFSET_BITS = $clog2(INSTRUCTION_BYTES);
  localparam int unsigned SET_BITS = $clog2(SET_COUNT);
  localparam int unsigned TAG_BITS = XLEN - SET_BITS - OFFSET_BITS;
  localparam int unsigned WAY_BITS = $clog2(BTB_WAY_COUNT);
  typedef logic [SET_BITS-1:0] set_index_t;
  typedef logic [WAY_BITS-1:0] way_index_t;
  typedef logic [TAG_BITS-1:0] tag_t;

  initial begin
    if ((BTB_WAY_COUNT != 2 && BTB_WAY_COUNT != 4) ||
        BTB_ENTRY_COUNT <= BTB_WAY_COUNT ||
        (BTB_ENTRY_COUNT & (BTB_ENTRY_COUNT - 1)) != 0)
      $fatal(1, "compact BTB requires two/four ways and power-of-two entries above ways");
    if (BTB_POLICY > 1) $fatal(1, "compact BTB supports round-robin policies 0 and 1");
  end

  // 1. 共享索引和有效状态；每路载荷在下方按实际位宽实例化。
  set_index_t lookup_set_index, training_set_index;
  tag_t lookup_tag, training_tag;
  logic [BTB_WAY_COUNT-1:0] entry_present_array_q[SET_COUNT];
  way_index_t replacement_way_array_q[SET_COUNT];
  logic [BTB_WAY_COUNT-1:0] lookup_hit_vector, training_hit_vector;
  logic [BTB_WAY_COUNT-1:0] training_fit_vector;
  program_counter_t lookup_target_array[BTB_WAY_COUNT];
  branch_target_kind_e lookup_kind_array[BTB_WAY_COUNT];

  assign lookup_set_index = lookup_pc_i[OFFSET_BITS+:SET_BITS];
  assign training_set_index = training_pc_i[OFFSET_BITS+:SET_BITS];
  assign lookup_tag = lookup_pc_i[XLEN-1-:TAG_BITS];
  assign training_tag = training_pc_i[XLEN-1-:TAG_BITS];

  // 2. 并行查询结果合并；训练选择不在查询路径上。
  always_comb begin
    lookup_target_present_o = |lookup_hit_vector;
    lookup_target_pc_o = '0;
    lookup_target_kind_o = TARGET_KIND_CONDITIONAL_BRANCH;
    for (int unsigned way = 0; way < BTB_WAY_COUNT; way++) begin
      if (lookup_hit_vector[way]) begin
        lookup_target_pc_o |= lookup_target_array[way];
        lookup_target_kind_o = branch_target_kind_e'(lookup_target_kind_o | lookup_kind_array[way]);
      end
    end
  end

  // 3. 训练选路：可保留命中 → 可容纳空路 → 从指针开始轮转的可容纳路。
  logic training_write_enable, training_selection_present, training_eviction_event;
  way_index_t training_way_index;
  logic training_hit_present;
  assign training_hit_present = |training_hit_vector;
  assign training_write_enable = training_valid_i && !invalidate_i &&
      (BTB_POLICY == 0 || training_hit_present || training_taken_i ||
       training_kind_i != TARGET_KIND_CONDITIONAL_BRANCH);

  always_comb begin
    training_way_index = '0;
    training_selection_present = 1'b0;
    training_eviction_event = 1'b0;
    for (int unsigned way = 0; way < BTB_WAY_COUNT; way++) begin
      if (training_hit_vector[way] && training_fit_vector[way]) begin
        training_way_index = way_index_t'(way);
        training_selection_present = 1'b1;
      end
    end
    for (int unsigned way = 0; way < BTB_WAY_COUNT; way++) begin
      if (!training_selection_present && training_fit_vector[way] &&
          !entry_present_array_q[training_set_index][way]) begin
        training_way_index = way_index_t'(way);
        training_selection_present = 1'b1;
      end
    end
    for (int unsigned step = 0; step < BTB_WAY_COUNT; step++) begin
      way_index_t candidate_way_index;
      candidate_way_index = replacement_way_array_q[training_set_index] + way_index_t'(step);
      if (!training_selection_present && training_fit_vector[candidate_way_index]) begin
        training_way_index = candidate_way_index;
        training_selection_present = 1'b1;
        training_eviction_event = 1'b1;
      end
    end
  end

  // 4. 每路独立定宽阵列：完整 tag 读口、目标拼接、训练适配及同步写口。
  for (genvar way = 0; way < BTB_WAY_COUNT; way++) begin : g_way
    localparam int unsigned TARGET_BITS = int'(BTB_WAY_TARGET_BITS[way*8+:8]);
    tag_t tag_array_q[SET_COUNT];
    logic [TARGET_BITS-1:0] target_array_q[SET_COUNT];
    branch_target_kind_e kind_array_q[SET_COUNT];
    initial begin
      if (TARGET_BITS < 1 || TARGET_BITS > XLEN) $fatal(1, "target width must be in 1..XLEN");
    end
    assign lookup_hit_vector[way] = entry_present_array_q[lookup_set_index][way] &&
                                    tag_array_q[lookup_set_index] == lookup_tag;
    assign training_hit_vector[way] = entry_present_array_q[training_set_index][way] &&
                                      tag_array_q[training_set_index] == training_tag;
    assign lookup_kind_array[way] = kind_array_q[lookup_set_index];
    if (TARGET_BITS == XLEN) begin : g_full_target
      assign lookup_target_array[way] = target_array_q[lookup_set_index];
      assign training_fit_vector[way] = 1'b1;
    end else begin : g_short_target
      assign lookup_target_array[way] = {
        lookup_pc_i[XLEN-1:TARGET_BITS], target_array_q[lookup_set_index]
      };
      assign training_fit_vector[way] = training_pc_i[XLEN-1:TARGET_BITS] ==
                                       training_target_pc_i[XLEN-1:TARGET_BITS];
    end
    always_ff @(posedge clk_i) begin
      if (training_write_enable && training_selection_present && training_way_index == way_index_t'(way)) begin
        tag_array_q[training_set_index] <= training_tag;
        target_array_q[training_set_index] <= training_target_pc_i[TARGET_BITS-1:0];
        kind_array_q[training_set_index] <= training_kind_i;
      end
    end
  end

  // 5. 有效位与替换指针：目标跨越本路范围时清掉旧项，避免跨路重复。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned set_index = 0; set_index < SET_COUNT; set_index++) begin
        entry_present_array_q[set_index]   <= '0;
        replacement_way_array_q[set_index] <= '0;
      end
    end else if (invalidate_i) begin
      for (int unsigned set_index = 0; set_index < SET_COUNT; set_index++) begin
        entry_present_array_q[set_index]   <= '0;
        replacement_way_array_q[set_index] <= '0;
      end
    end else if (training_write_enable) begin
      for (int unsigned way = 0; way < BTB_WAY_COUNT; way++) begin
        if (training_hit_vector[way] && !training_fit_vector[way])
          entry_present_array_q[training_set_index][way] <= 1'b0;
      end
      if (training_selection_present)
        entry_present_array_q[training_set_index][training_way_index] <= 1'b1;
      if (training_eviction_event)
        replacement_way_array_q[training_set_index] <= training_way_index + way_index_t'(1);
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(lookup_hit_vector))
  else $error("compact BTB has duplicate lookup tags");
  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(training_hit_vector))
  else $error("compact BTB has duplicate training tags");
`endif
endmodule
