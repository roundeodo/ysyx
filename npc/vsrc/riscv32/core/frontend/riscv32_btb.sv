// 小容量两路/多路 BTB：组合查询与一个同步训练写口。
// 父模块已经寄存解析事件；这里直接比较当前表项并写回，没有待写队列或训练旁路。
module riscv32_btb
  import riscv32_pkg::*;
#(
    parameter int unsigned        BTB_ENTRY_COUNT     = riscv_config_pkg::BRANCH_TARGET_ENTRY_COUNT,
    parameter int unsigned        BTB_WAY_COUNT       = riscv_config_pkg::BRANCH_TARGET_WAY_COUNT,
    parameter int unsigned        BTB_POLICY          = riscv_config_pkg::BRANCH_TARGET_POLICY,
    parameter logic        [31:0] BTB_WAY_TARGET_BITS = riscv_config_pkg::BRANCH_TARGET_WAY_BITS
) (
    input  logic                clk_i,
    input  logic                rst_ni,
    input  program_counter_t    lookup_pc_i,
    output logic                lookup_target_present_o,
    output program_counter_t    lookup_target_pc_o,
    output branch_target_kind_e lookup_target_kind_o,

    input program_counter_t    training_pc_i,
    input program_counter_t    training_target_pc_i,
    input branch_target_kind_e training_kind_i,
    input logic                training_valid_i,
    input logic                training_taken_i,
    input logic                invalidate_i
);
  generate
    if (BTB_WAY_TARGET_BITS != 0) begin : g_compact
      riscv32_compact_btb #(
          .BTB_ENTRY_COUNT(BTB_ENTRY_COUNT),
          .BTB_WAY_COUNT(BTB_WAY_COUNT),
          .BTB_POLICY(BTB_POLICY),
          .BTB_WAY_TARGET_BITS(BTB_WAY_TARGET_BITS)
      ) u_compact_btb (
          .*
      );
    end else begin : g_full_target
      localparam int unsigned SET_COUNT = BTB_ENTRY_COUNT / BTB_WAY_COUNT;
      localparam int unsigned OFFSET_BITS = $clog2(INSTRUCTION_BYTES);
      localparam int unsigned SET_BITS = $clog2(SET_COUNT);
      localparam int unsigned TAG_BITS = XLEN - SET_BITS - OFFSET_BITS;
      localparam int unsigned WAY_BITS = (BTB_WAY_COUNT > 1) ? $clog2(BTB_WAY_COUNT) : 1;
      typedef logic [SET_BITS-1:0] set_index_t;
      typedef logic [WAY_BITS-1:0] way_index_t;
      typedef logic [TAG_BITS-1:0] tag_t;

      initial begin
        if (BTB_ENTRY_COUNT < 2 || (BTB_ENTRY_COUNT & (BTB_ENTRY_COUNT - 1)) != 0)
          $fatal(1, "BTB entries must be a power of two and at least 2");
        if (BTB_WAY_COUNT < 1 || (BTB_WAY_COUNT & (BTB_WAY_COUNT - 1)) != 0 ||
            BTB_WAY_COUNT >= BTB_ENTRY_COUNT)
          $fatal(1, "BTB ways must be a power of two smaller than entry count");
        if (BTB_POLICY > 3 || (BTB_POLICY == 3 && BTB_WAY_COUNT != 2))
          $fatal(1, "BTB policy must be 0..3; policy3 requires two ways");
      end

      // 1. 表状态：有效位与载荷分开，invalidate 只清有效位与替换指针。
      typedef struct packed {
        tag_t                tag;
        program_counter_t    target_pc;
        branch_target_kind_e kind;
      } entry_t;

      entry_t                         entry_array_q          [SET_COUNT] [BTB_WAY_COUNT];
      logic       [BTB_WAY_COUNT-1:0] entry_present_array_q  [SET_COUNT];
      way_index_t                     replacement_way_array_q[SET_COUNT];
      logic       [              1:0] reuse_array_q          [SET_COUNT] [BTB_WAY_COUNT];

      // 2. 查询读口：读取一个 set，并行比较各 way，合并唯一命中项。
      set_index_t                     lookup_set_index;
      tag_t                           lookup_tag;
      logic       [BTB_WAY_COUNT-1:0] lookup_hit_vector;

      assign lookup_set_index = lookup_pc_i[OFFSET_BITS+:SET_BITS];
      assign lookup_tag       = lookup_pc_i[XLEN-1-:TAG_BITS];

      always_comb begin
        lookup_hit_vector    = '0;
        lookup_target_pc_o   = '0;
        lookup_target_kind_o = TARGET_KIND_CONDITIONAL_BRANCH;
        for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
          lookup_hit_vector[way_index] = entry_present_array_q[lookup_set_index][way_index] &&
                                        (entry_array_q[lookup_set_index][way_index].tag == lookup_tag);
          // 命中保证 one-hot；按位合并避免以 way 数量增长的目标优先级链。
          if (lookup_hit_vector[way_index]) begin
            lookup_target_pc_o |= entry_array_q[lookup_set_index][way_index].target_pc;
            lookup_target_kind_o = branch_target_kind_e'(
                lookup_target_kind_o | entry_array_q[lookup_set_index][way_index].kind);
          end
        end
        lookup_target_present_o = |lookup_hit_vector;
      end

      // 3. 训练选择：同 tag 优先；否则选第一个空 way；全部占用才使用轮转指针。
      set_index_t       training_set_index;
      tag_t             training_tag;
      way_index_t       training_way_index;
      way_index_t       replacement_next_way;
      logic             training_hit_present;
      logic             empty_way_present;
      logic             training_write_enable;
      logic       [1:0] maximum_reuse;
      logic       [1:0] age_amount;

      assign training_set_index = training_pc_i[OFFSET_BITS+:SET_BITS];
      assign training_tag = training_pc_i[XLEN-1-:TAG_BITS];
      // 只限制新表项准入；已有条目的更新和父模块的 BHT/RAS 训练仍然保留。
      assign training_write_enable = training_valid_i && !invalidate_i &&
          (BTB_POLICY == 0 || training_hit_present || training_taken_i ||
           training_kind_i != TARGET_KIND_CONDITIONAL_BRANCH);

      always_comb begin
        training_way_index = replacement_way_array_q[training_set_index];
        maximum_reuse      = '0;
        if (BTB_POLICY == 2) begin
          training_way_index = '0;
          maximum_reuse = reuse_array_q[training_set_index][0];
          for (int unsigned way_index = 1; way_index < BTB_WAY_COUNT; way_index++) begin
            if (reuse_array_q[training_set_index][way_index] > maximum_reuse) begin
              maximum_reuse = reuse_array_q[training_set_index][way_index];
              training_way_index = way_index_t'(way_index);
            end
          end
        end
        training_hit_present = 1'b0;
        empty_way_present    = 1'b0;
        for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
          if (entry_present_array_q[training_set_index][way_index] &&
              entry_array_q[training_set_index][way_index].tag == training_tag) begin
            training_way_index   = way_index_t'(way_index);
            training_hit_present = 1'b1;
          end else if (!entry_present_array_q[training_set_index][way_index] &&
                       !empty_way_present && !training_hit_present) begin
            training_way_index = way_index_t'(way_index);
            empty_way_present  = 1'b1;
          end
        end
        replacement_next_way = training_way_index + way_index_t'(1);
        if (training_way_index == way_index_t'(BTB_WAY_COUNT - 1)) replacement_next_way = '0;
        age_amount = (!training_hit_present && !empty_way_present) ? 2'd3 - maximum_reuse : 2'd0;
      end

      // 4. 复用状态：只在策略2实例化。命中且跳转才提升，新分配置2；查询不经过此路径。
      if (BTB_POLICY == 2) begin : g_reuse
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin
            for (int unsigned set_index = 0; set_index < SET_COUNT; set_index++) begin
              for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++)
              reuse_array_q[set_index][way_index] <= 2'd3;
            end
          end else if (invalidate_i) begin
            for (int unsigned set_index = 0; set_index < SET_COUNT; set_index++) begin
              for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++)
              reuse_array_q[set_index][way_index] <= 2'd3;
            end
          end else if (training_write_enable) begin
            if (!training_hit_present) begin
              for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++)
              reuse_array_q[training_set_index][way_index] <=
                      reuse_array_q[training_set_index][way_index] + age_amount;
              reuse_array_q[training_set_index][training_way_index] <= 2'd2;
            end else if (training_taken_i) begin
              reuse_array_q[training_set_index][training_way_index] <= 2'd0;
            end
          end
        end
      end

      // 5. 同步写口：连续训练在下一周期直接看到本沿写入的状态，不需要旁路。
      always_ff @(posedge clk_i) begin
        if (training_write_enable) begin
          entry_array_q[training_set_index][training_way_index].tag       <= training_tag;
          entry_array_q[training_set_index][training_way_index].target_pc <= training_target_pc_i;
          entry_array_q[training_set_index][training_way_index].kind      <= training_kind_i;
        end
      end

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
          entry_present_array_q[training_set_index][training_way_index] <= 1'b1;
          if ((BTB_POLICY < 2 && !training_hit_present && !empty_way_present) ||
              (BTB_POLICY == 3 && (!training_hit_present || training_taken_i)))
            replacement_way_array_q[training_set_index] <= replacement_next_way;
        end
      end

`ifndef SYNTHESIS
      assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(lookup_hit_vector))
      else $error("multiple BTB ways matched the same lookup PC");
`endif
    end
  endgenerate
endmodule
