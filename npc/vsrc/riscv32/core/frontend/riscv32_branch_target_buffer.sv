// 分支目标缓冲：表项、替换、查询快照和训练旁路均由本模块管理。
// lookup_capture_i与父模块查询一级的PC/epoch采样共用同一次握手。
// training_*输入已经过共享解析事件寄存器；本模块再完成set快照、选way和写入。
module riscv32_branch_target_buffer
  import riscv32_pkg::*;
#(
    parameter int unsigned BTB_ENTRY_COUNT = riscv_config_pkg::BRANCH_TARGET_ENTRY_COUNT,
    parameter int unsigned BTB_WAY_COUNT   = riscv_config_pkg::BRANCH_TARGET_WAY_COUNT
) (
    input  logic                clk_i,
    input  logic                rst_ni,
    input  program_counter_t    lookup_request_pc_i,
    input  logic                lookup_capture_i,
    input  program_counter_t    lookup_query_pc_i,
    input  logic                lookup_query_valid_i,
    output logic                lookup_target_present_o,
    output program_counter_t    lookup_target_pc_o,
    output branch_target_kind_e lookup_target_kind_o,

    input  program_counter_t training_pc_i,
    input  program_counter_t training_target_pc_i,
    input  xlen_data_t       training_immediate_i,
    input  control_flow_op_e training_op_i,
    input  arch_reg_idx_t    training_rs1_i,
    input  arch_reg_idx_t    training_rd_i,
    input  logic             training_valid_i,
    input  logic             invalidate_i
);
  localparam int unsigned BTB_SET_COUNT = BTB_ENTRY_COUNT / BTB_WAY_COUNT;
  localparam int unsigned INSTRUCTION_OFFSET_WIDTH = $clog2(INSTRUCTION_BYTES);
  localparam int unsigned BRANCH_TARGET_INDEX_WIDTH = $clog2(BTB_SET_COUNT);
  localparam int unsigned BRANCH_TARGET_TAG_WIDTH =
      XLEN - BRANCH_TARGET_INDEX_WIDTH - INSTRUCTION_OFFSET_WIDTH;
  localparam int unsigned BRANCH_TARGET_WAY_INDEX_WIDTH =
      (BTB_WAY_COUNT > 1) ? $clog2(BTB_WAY_COUNT) : 1;

  typedef logic [BRANCH_TARGET_INDEX_WIDTH-1:0] branch_target_index_t;
  typedef logic [BRANCH_TARGET_WAY_INDEX_WIDTH-1:0] branch_target_way_index_t;
  typedef logic [BRANCH_TARGET_TAG_WIDTH-1:0] branch_target_tag_t;

  typedef struct packed {
    logic                present;
    branch_target_tag_t  pc_tag;
    program_counter_t    target_pc;
    branch_target_kind_e kind;
  } branch_target_entry_t;

  // 训练写事务同时供数组写口和后续训练快照使用，不旁路到查询端。
  typedef struct packed {
    logic                     present;
    branch_target_index_t     set_index;
    branch_target_way_index_t way_index;
    branch_target_entry_t     entry;
    logic                     replacement_way_update_present;
    branch_target_way_index_t next_replacement_way;
  } branch_target_update_t;

  // BTB训练选择级只保存一个set的快照。把动态set读取与tag比较拆到两个周期，避免
  // 上一项训练经整张BTB选择网络反馈到下一项训练寄存器的D端。
  typedef struct packed {
    logic                     present;
    branch_target_index_t     set_index;
    branch_target_tag_t       pc_tag;
    program_counter_t         target_pc;
    branch_target_kind_e      kind;
    branch_target_way_index_t replacement_way;
  } branch_target_training_selection_t;

  branch_target_entry_t     branch_target_entry_array_q[BTB_SET_COUNT][BTB_WAY_COUNT];
  branch_target_way_index_t branch_target_replacement_way_q[BTB_SET_COUNT];

  initial begin
    if ((BTB_ENTRY_COUNT < 2) || ((BTB_ENTRY_COUNT & (BTB_ENTRY_COUNT - 1)) != 0)) begin
      $fatal(1, "branch target entry count must be a power of two and at least 2");
    end
    if ((BTB_WAY_COUNT < 1) ||
        ((BTB_WAY_COUNT & (BTB_WAY_COUNT - 1)) != 0) ||
        (BTB_WAY_COUNT >= BTB_ENTRY_COUNT)) begin
      $fatal(1, "branch target way count must be a power of two smaller than entry count");
    end
  end

  // 查询一级：保存选中的set；查询二级按父模块持有的同一PC比较tag。
  branch_target_index_t     lookup_request_branch_target_index;
  branch_target_tag_t       lookup_query_branch_target_tag;
  branch_target_entry_t     lookup_query_way_entry_array_q[BTB_WAY_COUNT];
  branch_target_entry_t     lookup_branch_target_entry;
  logic [BTB_WAY_COUNT-1:0] lookup_branch_target_hit_way_vector;

  assign lookup_request_branch_target_index =
      lookup_request_pc_i[INSTRUCTION_OFFSET_WIDTH +: BRANCH_TARGET_INDEX_WIDTH];
  assign lookup_query_branch_target_tag =
      lookup_query_pc_i[XLEN-1:BRANCH_TARGET_INDEX_WIDTH+INSTRUCTION_OFFSET_WIDTH];
  assign lookup_target_pc_o   = lookup_branch_target_entry.target_pc;
  assign lookup_target_kind_o = lookup_branch_target_entry.kind;

  always_comb begin
    lookup_branch_target_entry          = '0;
    lookup_branch_target_hit_way_vector = '0;
    for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
      if (lookup_query_way_entry_array_q[way_index].present &&
          (lookup_query_way_entry_array_q[way_index].pc_tag ==
           lookup_query_branch_target_tag)) begin
        lookup_branch_target_hit_way_vector[way_index] = 1'b1;
        lookup_branch_target_entry = lookup_query_way_entry_array_q[way_index];
      end
    end
    lookup_target_present_o = |lookup_branch_target_hit_way_vector;
  end

  // 父模块在flush时禁止capture并清query valid；旧快照保持但不可见。
  // invalidate清数组，不另行取消查询；取消动作仍由父模块的flush负责。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
        lookup_query_way_entry_array_q[way_index] <= '0;
      end
    end else if (lookup_capture_i) begin
      for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
        lookup_query_way_entry_array_q[way_index] <=
            branch_target_entry_array_q[lookup_request_branch_target_index][way_index];
      end
    end
  end

  // 训练输入的索引、tag及控制流种类。
  branch_target_index_t     resolved_branch_target_index;
  branch_target_way_index_t branch_target_training_write_way;
  logic                     branch_target_training_hit_present;
  logic                     branch_target_training_invalid_way_present;
  branch_target_tag_t       resolved_branch_target_tag;
  branch_target_kind_e      resolved_branch_target_kind;
  logic                     resolved_rd_is_link_register;
  logic                     resolved_rs1_is_link_register;
  logic                     resolved_return_instruction_present;

  assign resolved_branch_target_index =
      training_pc_i[INSTRUCTION_OFFSET_WIDTH +: BRANCH_TARGET_INDEX_WIDTH];
  assign resolved_branch_target_tag =
      training_pc_i[XLEN-1:BRANCH_TARGET_INDEX_WIDTH+INSTRUCTION_OFFSET_WIDTH];

  function automatic logic is_link_register(input arch_reg_idx_t register_index);
    return (register_index == arch_reg_idx_t'(1)) || (register_index == arch_reg_idx_t'(5));
  endfunction

  assign resolved_rd_is_link_register = is_link_register(training_rd_i);
  assign resolved_rs1_is_link_register = is_link_register(training_rs1_i);
  // RISC-V用x1/x5的rd/rs1组合向硬件提示call、return和协程式pop+push。
  assign resolved_return_instruction_present =
      (training_op_i == CF_JALR) && resolved_rs1_is_link_register &&
      (!resolved_rd_is_link_register ||
       (training_rd_i != training_rs1_i)) &&
      (training_immediate_i == '0);

  always_comb begin
    unique case (training_op_i)
      CF_BRANCH: resolved_branch_target_kind = TARGET_KIND_CONDITIONAL_BRANCH;
      CF_JAL:    resolved_branch_target_kind = TARGET_KIND_DIRECT_JUMP;
      CF_JALR: begin
        resolved_branch_target_kind = resolved_return_instruction_present ?
                                      TARGET_KIND_RETURN : TARGET_KIND_INDIRECT_JUMP;
      end
      default:   resolved_branch_target_kind = TARGET_KIND_CONDITIONAL_BRANCH;
    endcase
  end

  // 训练寄存状态不出模块：同set更新的优先级为新生成事务、待写事务、数组。
  branch_target_training_selection_t branch_target_training_selection_q;
  branch_target_entry_t              branch_target_training_way_entry_array_q[BTB_WAY_COUNT];
  branch_target_update_t             branch_target_update_d;
  branch_target_update_t             branch_target_update_q;

  // 训练快照在解析事件之后增加一级时序边界。数组只在这里按set读取；同拍即将提交
  // 和即将生成的更新都旁路到快照，保证连续训练同一set时仍能看到最新表项与替换位置。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      branch_target_training_selection_q <= '0;
      for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
        branch_target_training_way_entry_array_q[way_index] <= '0;
      end
    end else if (invalidate_i) begin
      branch_target_training_selection_q.present <= 1'b0;
    end else begin
      branch_target_training_selection_q.present         <=
          training_valid_i;
      branch_target_training_selection_q.set_index       <= resolved_branch_target_index;
      branch_target_training_selection_q.pc_tag          <= resolved_branch_target_tag;
      branch_target_training_selection_q.target_pc       <=
          training_target_pc_i;
      branch_target_training_selection_q.kind            <= resolved_branch_target_kind;
      branch_target_training_selection_q.replacement_way <=
          branch_target_replacement_way_q[resolved_branch_target_index];

      for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
        branch_target_training_way_entry_array_q[way_index] <=
            branch_target_entry_array_q[resolved_branch_target_index][way_index];

        if (branch_target_update_q.present &&
            (branch_target_update_q.set_index == resolved_branch_target_index) &&
            (branch_target_update_q.way_index == branch_target_way_index_t'(way_index))) begin
          branch_target_training_way_entry_array_q[way_index] <= branch_target_update_q.entry;
        end

        if (branch_target_update_d.present &&
            (branch_target_update_d.set_index == resolved_branch_target_index) &&
            (branch_target_update_d.way_index == branch_target_way_index_t'(way_index))) begin
          branch_target_training_way_entry_array_q[way_index] <= branch_target_update_d.entry;
        end
      end

      if (branch_target_update_q.present &&
          branch_target_update_q.replacement_way_update_present &&
          (branch_target_update_q.set_index == resolved_branch_target_index)) begin
        branch_target_training_selection_q.replacement_way <=
            branch_target_update_q.next_replacement_way;
      end

      if (branch_target_update_d.present &&
          branch_target_update_d.replacement_way_update_present &&
          (branch_target_update_d.set_index == resolved_branch_target_index)) begin
        branch_target_training_selection_q.replacement_way <=
            branch_target_update_d.next_replacement_way;
      end
    end
  end

  // 训练优先更新快照中同PC的已有way，其次占用第一个invalid way；set已满时才采用
  // 快照携带的round-robin位置。比较对象已经寄存，不再读取动态索引的BTB数组。
  always_comb begin
    branch_target_training_write_way = branch_target_training_selection_q.replacement_way;
    branch_target_training_hit_present = 1'b0;
    branch_target_training_invalid_way_present = 1'b0;

    for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
      branch_target_entry_t compared_entry;
      compared_entry = branch_target_training_way_entry_array_q[way_index];

      if (compared_entry.present &&
          (compared_entry.pc_tag == branch_target_training_selection_q.pc_tag)) begin
        branch_target_training_write_way   = branch_target_way_index_t'(way_index);
        branch_target_training_hit_present = 1'b1;
      end else if (!compared_entry.present &&
                   !branch_target_training_invalid_way_present &&
                   !branch_target_training_hit_present) begin
        branch_target_training_write_way = branch_target_way_index_t'(way_index);
        branch_target_training_invalid_way_present = 1'b1;
      end
    end
  end

  // 选择级只生成一个小型写事务；下一拍数组写口不再包含tag比较、invalid搜索和
  // replacement选择。每拍可覆盖branch_target_update_q，因此吞吐仍为一项/拍。
  always_comb begin
    branch_target_update_d                                 = '0;
    branch_target_update_d.present                         =
        branch_target_training_selection_q.present;
    branch_target_update_d.set_index                       =
        branch_target_training_selection_q.set_index;
    branch_target_update_d.way_index                       = branch_target_training_write_way;
    branch_target_update_d.entry.present                   = 1'b1;
    branch_target_update_d.entry.pc_tag                    =
        branch_target_training_selection_q.pc_tag;
    branch_target_update_d.entry.target_pc                 =
        branch_target_training_selection_q.target_pc;
    branch_target_update_d.entry.kind                      = branch_target_training_selection_q.kind;
    branch_target_update_d.replacement_way_update_present  =
        branch_target_training_selection_q.present &&
        !branch_target_training_hit_present && !branch_target_training_invalid_way_present;
    branch_target_update_d.next_replacement_way            =
        (branch_target_training_write_way ==
         branch_target_way_index_t'(BTB_WAY_COUNT - 1)) ?
        '0 : branch_target_training_write_way + branch_target_way_index_t'(1);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      branch_target_update_q <= '0;
    end else if (invalidate_i) begin
      branch_target_update_q <= '0;
    end else begin
      branch_target_update_q <= branch_target_update_d;
    end
  end

  // BTB在控制流真正到达EX并形成结果后训练。fence.i清除present位即可，tag/target
  // payload在present=0时不可见，因此不为大数组增加无意义的复位网络。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned set_index = 0; set_index < BTB_SET_COUNT; set_index++) begin
        branch_target_replacement_way_q[set_index] <= '0;
        for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
          branch_target_entry_array_q[set_index][way_index].present <= 1'b0;
        end
      end
    end else if (invalidate_i) begin
      for (int unsigned set_index = 0; set_index < BTB_SET_COUNT; set_index++) begin
        branch_target_replacement_way_q[set_index] <= '0;
        for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
          branch_target_entry_array_q[set_index][way_index].present <= 1'b0;
        end
      end
    end else if (branch_target_update_q.present) begin
      branch_target_entry_array_q[branch_target_update_q.set_index][
          branch_target_update_q.way_index
      ] <= branch_target_update_q.entry;

      if (branch_target_update_q.replacement_way_update_present) begin
        branch_target_replacement_way_q[branch_target_update_q.set_index] <=
            branch_target_update_q.next_replacement_way;
      end
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    lookup_query_valid_i |-> $onehot0(lookup_branch_target_hit_way_vector))
  else $error("multiple BTB ways matched the same lookup PC");
`endif
endmodule
