// 前端控制流预测器。
//
// 小容量BTB/BHT/RAS查询拆成两级流水：第一级读取所选表项，第二级完成tag比较和
// 目标选择。两个弹性级都支持同拍移出旧项并接收新项，因此非跳转路径仍可保持
// 每拍一次查询，同时不再把数组选择和预测判定串在同一条关键路径上。
module riscv32_fetch_control_flow_predictor
  import riscv32_pkg::*;
#(
    parameter int unsigned BHT_ENTRY_COUNT = riscv_config_pkg::BRANCH_HISTORY_ENTRY_COUNT,
    parameter int unsigned BTB_ENTRY_COUNT = riscv_config_pkg::BRANCH_TARGET_ENTRY_COUNT,
    parameter int unsigned BTB_WAY_COUNT   = riscv_config_pkg::BRANCH_TARGET_WAY_COUNT,
    parameter int unsigned RAS_ENTRY_COUNT = riscv_config_pkg::RETURN_STACK_ENTRY_COUNT
) (
    input logic clk_i,
    input logic rst_ni,

    input  program_counter_t   lookup_request_pc_i,
    input  fetch_epoch_t       lookup_request_epoch_i,
    input  logic               lookup_request_valid_i,
    output logic               lookup_request_ready_o,
    output program_counter_t   lookup_response_pc_o,
    output fetch_epoch_t       lookup_response_epoch_o,
    output branch_prediction_t lookup_prediction_o,
    output program_counter_t   lookup_next_pc_o,
    output logic               lookup_response_valid_o,
    input  logic               lookup_response_ready_i,

    input program_counter_t resolved_control_flow_pc_i,
    input program_counter_t resolved_control_flow_target_i,
    input xlen_data_t       resolved_control_flow_imm_i,
    input control_flow_op_e resolved_control_flow_op_i,
    input arch_reg_idx_t    resolved_control_flow_rs1_i,
    input arch_reg_idx_t    resolved_control_flow_rd_i,
    input logic             resolved_control_flow_occurred_i,
    input logic             resolved_control_flow_taken_i,

    // redirect只清除当前查询流水，不清除训练状态；fence.i才清除可能过期的BTB内容。
    input logic flush_lookup_i,
    input logic invalidate_i
);
  localparam int unsigned BTB_SET_COUNT = BTB_ENTRY_COUNT / BTB_WAY_COUNT;
  localparam int unsigned BRANCH_HISTORY_INDEX_WIDTH = $clog2(BHT_ENTRY_COUNT);
  localparam int unsigned BRANCH_TARGET_INDEX_WIDTH = $clog2(BTB_SET_COUNT);
  localparam int unsigned BRANCH_TARGET_TAG_WIDTH = XLEN - BRANCH_TARGET_INDEX_WIDTH - $clog2(
      INSTRUCTION_BYTES
  );
  localparam int unsigned BRANCH_TARGET_WAY_INDEX_WIDTH = (BTB_WAY_COUNT > 1) ? $clog2(
      BTB_WAY_COUNT
  ) : 1;
  localparam int unsigned RETURN_STACK_INDEX_WIDTH = $clog2(RAS_ENTRY_COUNT);
  localparam int unsigned RETURN_STACK_COUNT_WIDTH = $clog2(RAS_ENTRY_COUNT + 1);

  typedef logic [BRANCH_HISTORY_INDEX_WIDTH-1:0] branch_history_index_t;
  typedef logic [BRANCH_TARGET_INDEX_WIDTH-1:0] branch_target_index_t;
  typedef logic [BRANCH_TARGET_WAY_INDEX_WIDTH-1:0] branch_target_way_index_t;
  typedef logic [BRANCH_TARGET_TAG_WIDTH-1:0] branch_target_tag_t;
  typedef logic [RETURN_STACK_INDEX_WIDTH-1:0] return_stack_index_t;
  typedef logic [RETURN_STACK_COUNT_WIDTH-1:0] return_stack_count_t;

  typedef enum logic [1:0] {
    TARGET_KIND_CONDITIONAL_BRANCH,
    TARGET_KIND_DIRECT_JUMP,
    TARGET_KIND_INDIRECT_JUMP,
    TARGET_KIND_RETURN
  } branch_target_kind_e;

  typedef struct packed {
    logic                present;
    branch_target_tag_t  pc_tag;
    program_counter_t    target_pc;
    branch_target_kind_e kind;
  } branch_target_entry_t;

  // EX解析结果先完整进入训练寄存器，再驱动BTB/BHT/RAS写口。该边界切断
  // execute_packet经过EXU和预测表项选择逻辑直达大数组D端的跨核长组合路径。
  // 寄存器每拍都可接收一个解析事件，因此不会降低连续控制流指令的训练吞吐。
  typedef struct packed {
    logic             present;
    program_counter_t pc;
    program_counter_t target_pc;
    xlen_data_t       immediate;
    control_flow_op_e op;
    arch_reg_idx_t    rs1;
    arch_reg_idx_t    rd;
    logic             taken;
  } resolved_control_flow_update_t;

  // BTB训练分成“选择set/way”和“写表项”两级。保存即将写入的完整表项，既缩短
  // 训练关键路径，也允许查询端对尚未落入数组的最近一次更新进行精确旁路。
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

  typedef enum logic [1:0] {
    RETURN_STACK_UPDATE_NONE,
    RETURN_STACK_UPDATE_PUSH,
    RETURN_STACK_UPDATE_POP,
    RETURN_STACK_UPDATE_POP_PUSH
  } return_stack_update_op_e;

  // 先把RISC-V的rd/rs1/op提示译成简单的RAS微操作，再驱动RAS数组写口。
  // 这样复杂的call/return识别不会直接落到每个RAS数据寄存器的D端。
  typedef struct packed {
    return_stack_update_op_e op;
    program_counter_t        return_pc;
  } return_stack_update_t;

  typedef struct packed {
    program_counter_t pc;
    fetch_epoch_t     epoch;
    logic [1:0]       branch_history_counter;
    logic             return_target_present;
    program_counter_t return_target_pc;
  } lookup_query_t;

  typedef struct packed {
    program_counter_t   pc;
    fetch_epoch_t       epoch;
    branch_prediction_t prediction;
    program_counter_t   next_pc;
  } lookup_response_t;

  branch_target_entry_t branch_target_entry_array_q[BTB_SET_COUNT][BTB_WAY_COUNT];
  branch_target_way_index_t branch_target_replacement_way_q[BTB_SET_COUNT];
  logic [1:0] branch_history_counter_array_q[BHT_ENTRY_COUNT];
  program_counter_t return_stack_pc_array_q[RAS_ENTRY_COUNT];

  resolved_control_flow_update_t resolved_control_flow_update_q;
  branch_target_training_selection_t branch_target_training_selection_q;
  branch_target_entry_t branch_target_training_way_entry_array_q[BTB_WAY_COUNT];
  branch_target_update_t branch_target_update_d;
  branch_target_update_t branch_target_update_q;
  return_stack_update_t return_stack_update_d;
  return_stack_update_t return_stack_update_q;

  lookup_query_t    lookup_query_q;
  lookup_response_t lookup_response_q;
  logic             lookup_query_present_q;
  logic             lookup_response_present_q;
  logic             lookup_query_stage_ready;
  logic             lookup_response_stage_ready;

  branch_target_index_t lookup_request_branch_target_index;
  branch_history_index_t lookup_request_branch_history_index;
  branch_target_tag_t lookup_query_branch_target_tag;
  branch_target_entry_t lookup_query_way_entry_array_q[BTB_WAY_COUNT];
  branch_target_entry_t lookup_branch_target_entry;
  logic [BTB_WAY_COUNT-1:0] lookup_branch_target_hit_way_vector;
  logic lookup_branch_target_present;
  logic conditional_branch_predicted_taken;
  logic predicted_taken;
  program_counter_t predicted_target_pc;
  branch_prediction_t lookup_prediction;
  program_counter_t   lookup_next_pc;

  branch_target_index_t resolved_branch_target_index;
  branch_target_way_index_t branch_target_training_write_way;
  logic branch_target_training_hit_present;
  logic branch_target_training_invalid_way_present;
  branch_target_tag_t resolved_branch_target_tag;
  branch_history_index_t resolved_branch_history_index;
  branch_target_kind_e resolved_branch_target_kind;
  logic resolved_rd_is_link_register;
  logic resolved_rs1_is_link_register;
  logic resolved_return_instruction_present;
  logic incoming_rd_is_link_register;
  logic incoming_rs1_is_link_register;
  logic incoming_return_instruction_present;
  logic incoming_return_stack_push;
  logic incoming_return_stack_pop;

  return_stack_index_t return_stack_write_index_q;
  return_stack_index_t return_stack_top_index;
  return_stack_count_t return_stack_entry_count_q;
  program_counter_t return_stack_top_pc_q;

  initial begin
    if ((BHT_ENTRY_COUNT < 2) || ((BHT_ENTRY_COUNT & (BHT_ENTRY_COUNT - 1)) != 0)) begin
      $fatal(1, "branch history entry count must be a power of two and at least 2");
    end
    if ((BTB_ENTRY_COUNT < 2) || ((BTB_ENTRY_COUNT & (BTB_ENTRY_COUNT - 1)) != 0)) begin
      $fatal(1, "branch target entry count must be a power of two and at least 2");
    end
    if ((BTB_WAY_COUNT < 1) ||
        ((BTB_WAY_COUNT & (BTB_WAY_COUNT - 1)) != 0) ||
        (BTB_WAY_COUNT >= BTB_ENTRY_COUNT)) begin
      $fatal(1, "branch target way count must be a power of two smaller than entry count");
    end
    if ((RAS_ENTRY_COUNT < 2) || ((RAS_ENTRY_COUNT & (RAS_ENTRY_COUNT - 1)) != 0)) begin
      $fatal(1, "return stack entry count must be a power of two and at least 2");
    end
  end

  function automatic logic is_link_register(input arch_reg_idx_t register_index);
    return (register_index == arch_reg_idx_t'(1)) || (register_index == arch_reg_idx_t'(5));
  endfunction

  function automatic return_stack_index_t increment_return_stack_index(
      input return_stack_index_t current_index);
    return (current_index == return_stack_index_t'(RAS_ENTRY_COUNT - 1)) ?
           '0 : current_index + return_stack_index_t'(1);
  endfunction

  function automatic return_stack_index_t decrement_return_stack_index(
      input return_stack_index_t current_index);
    return (current_index == '0) ?
           return_stack_index_t'(RAS_ENTRY_COUNT - 1) :
           current_index - return_stack_index_t'(1);
  endfunction

  function automatic logic [1:0] update_branch_history_counter(input logic [1:0] current_counter,
                                                               input logic branch_taken);
    if (branch_taken) begin
      return (current_counter == 2'b11) ? current_counter : current_counter + 2'b01;
    end
    return (current_counter == 2'b00) ? current_counter : current_counter - 2'b01;
  endfunction

  // 两级弹性流水逐级传播ready。响应反压时仍可利用空闲查询级暂存一个请求；
  // 两级都被占用后才停止接收，不把下游ready直接接入BTB/BHT数据路径。
  assign lookup_response_stage_ready =
      !lookup_response_present_q || lookup_response_ready_i;
  assign lookup_query_stage_ready =
      !lookup_query_present_q || lookup_response_stage_ready;
  assign lookup_request_ready_o = lookup_query_stage_ready && !flush_lookup_i;
  assign lookup_response_pc_o    = lookup_response_q.pc;
  assign lookup_response_epoch_o = lookup_response_q.epoch;
  assign lookup_prediction_o     = lookup_response_q.prediction;
  assign lookup_next_pc_o        = lookup_response_q.next_pc;
  assign lookup_response_valid_o = lookup_response_present_q;

  assign lookup_request_branch_target_index =
      lookup_request_pc_i[BRANCH_TARGET_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )-1:$clog2(
      INSTRUCTION_BYTES
  )];
  assign lookup_request_branch_history_index =
      lookup_request_pc_i[BRANCH_HISTORY_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )-1:$clog2(
      INSTRUCTION_BYTES
  )];

  // 第一级已经寄存请求PC和所选BTB ways；第二级只做并行tag比较和目标选择。
  // 两路组织相对同容量direct-map只增加一个tag比较器、目标选择器和每set一位替换状态。
  assign lookup_query_branch_target_tag = lookup_query_q.pc[XLEN-1:BRANCH_TARGET_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )];
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
    lookup_branch_target_present = |lookup_branch_target_hit_way_vector;
  end

  assign conditional_branch_predicted_taken = lookup_query_q.branch_history_counter[1];

  assign return_stack_top_index = decrement_return_stack_index(return_stack_write_index_q);

  // BTB miss默认顺序取指。return优先采用RAS；RAS为空时退回BTB记录的上一次目标，
  // 错误目标仍会由EX按请求随身携带的prediction精确检查并恢复。
  always_comb begin
    predicted_taken     = 1'b0;
    predicted_target_pc = lookup_branch_target_entry.target_pc;

    if (lookup_branch_target_present) begin
      unique case (lookup_branch_target_entry.kind)
        TARGET_KIND_CONDITIONAL_BRANCH: predicted_taken = conditional_branch_predicted_taken;

        TARGET_KIND_DIRECT_JUMP, TARGET_KIND_INDIRECT_JUMP: predicted_taken = 1'b1;

        TARGET_KIND_RETURN: begin
          predicted_taken = 1'b1;
          if (lookup_query_q.return_target_present) begin
            predicted_target_pc = lookup_query_q.return_target_pc;
          end
        end

        default: ;
      endcase
    end

    // 当前不支持C扩展，错误的2字节对齐目标不能作为有效预测送入前端。
    if (predicted_target_pc[1:0] != 2'b00) begin
      predicted_taken = 1'b0;
    end

    lookup_prediction                  = '0;
    lookup_prediction.predicted_taken  = predicted_taken;
    lookup_prediction.predicted_target = predicted_taken ? predicted_target_pc : '0;
    lookup_next_pc                     = predicted_taken ?
                                         predicted_target_pc :
                                         lookup_query_q.pc +
                                         program_counter_t'(INSTRUCTION_BYTES);
  end

  // 第一级在请求握手时读取所选BTB ways、BHT计数器和RAS栈顶快照。第二级在能够
  // 前推时寄存比较结果。非阻塞赋值保证同一时钟沿先用旧查询产生响应，再装入新查询。
  // flush同时清空两级在途预测，但不清除BTB/BHT/RAS训练状态。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lookup_query_q            <= '0;
      lookup_response_q         <= '0;
      lookup_query_present_q    <= 1'b0;
      lookup_response_present_q <= 1'b0;
      for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
        lookup_query_way_entry_array_q[way_index] <= '0;
      end
    end else if (flush_lookup_i) begin
      lookup_query_present_q    <= 1'b0;
      lookup_response_present_q <= 1'b0;
    end else begin
      if (lookup_response_stage_ready) begin
        lookup_response_present_q <= lookup_query_present_q;
        if (lookup_query_present_q) begin
          lookup_response_q.pc         <= lookup_query_q.pc;
          lookup_response_q.epoch      <= lookup_query_q.epoch;
          lookup_response_q.prediction <= lookup_prediction;
          lookup_response_q.next_pc    <= lookup_next_pc;
        end
      end

      if (lookup_query_stage_ready) begin
        lookup_query_present_q <= lookup_request_valid_i;
        if (lookup_request_valid_i) begin
          lookup_query_q.pc                     <= lookup_request_pc_i;
          lookup_query_q.epoch                  <= lookup_request_epoch_i;
          lookup_query_q.branch_history_counter <=
              branch_history_counter_array_q[lookup_request_branch_history_index];
          lookup_query_q.return_target_present  <= return_stack_entry_count_q != '0;
          lookup_query_q.return_target_pc       <= return_stack_top_pc_q;
          for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
            lookup_query_way_entry_array_q[way_index] <=
                branch_target_entry_array_q[lookup_request_branch_target_index][way_index];
          end
        end
      end
    end
  end

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
          resolved_control_flow_update_q.present;
      branch_target_training_selection_q.set_index       <= resolved_branch_target_index;
      branch_target_training_selection_q.pc_tag          <= resolved_branch_target_tag;
      branch_target_training_selection_q.target_pc       <=
          resolved_control_flow_update_q.target_pc;
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

  assign resolved_branch_target_index = resolved_control_flow_update_q.pc[BRANCH_TARGET_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )-1:$clog2(
      INSTRUCTION_BYTES
  )];
  assign resolved_branch_target_tag =
      resolved_control_flow_update_q.pc[XLEN-1:
                                        BRANCH_TARGET_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )];
  assign resolved_branch_history_index =
      resolved_control_flow_update_q.pc[BRANCH_HISTORY_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )-1:$clog2(
      INSTRUCTION_BYTES
  )];

  // 训练边界只在本模块保存微架构事件，不改变精确控制流恢复的时刻。invalidate
  // 优先丢弃同拍训练，防止fence.i清空预测状态后又被旧指令重新写入。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      resolved_control_flow_update_q <= '0;
    end else if (invalidate_i) begin
      resolved_control_flow_update_q <= '0;
    end else begin
      resolved_control_flow_update_q.present   <= resolved_control_flow_occurred_i;
      resolved_control_flow_update_q.pc        <= resolved_control_flow_pc_i;
      resolved_control_flow_update_q.target_pc <= resolved_control_flow_target_i;
      resolved_control_flow_update_q.immediate <= resolved_control_flow_imm_i;
      resolved_control_flow_update_q.op        <= resolved_control_flow_op_i;
      resolved_control_flow_update_q.rs1       <= resolved_control_flow_rs1_i;
      resolved_control_flow_update_q.rd        <= resolved_control_flow_rd_i;
      resolved_control_flow_update_q.taken     <= resolved_control_flow_taken_i;
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

  assign resolved_rd_is_link_register = is_link_register(resolved_control_flow_update_q.rd);
  assign resolved_rs1_is_link_register = is_link_register(resolved_control_flow_update_q.rs1);
  // RISC-V用x1/x5的rd/rs1组合向硬件提示call、return和协程式pop+push。
  assign resolved_return_instruction_present =
      (resolved_control_flow_update_q.op == CF_JALR) && resolved_rs1_is_link_register &&
      (!resolved_rd_is_link_register ||
       (resolved_control_flow_update_q.rd != resolved_control_flow_update_q.rs1)) &&
      (resolved_control_flow_update_q.immediate == '0);
  // RAS与完整控制流训练包在同一个EX边界并行采样，避免在预测器内部再串联一级
  // 完整训练寄存器。数组写入级只接收一种明确的栈操作和预先计算的return PC。
  assign incoming_rd_is_link_register  = is_link_register(resolved_control_flow_rd_i);
  assign incoming_rs1_is_link_register = is_link_register(resolved_control_flow_rs1_i);
  assign incoming_return_instruction_present =
      (resolved_control_flow_op_i == CF_JALR) && incoming_rs1_is_link_register &&
      (!incoming_rd_is_link_register ||
       (resolved_control_flow_rd_i != resolved_control_flow_rs1_i)) &&
      (resolved_control_flow_imm_i == '0);
  assign incoming_return_stack_push = resolved_control_flow_occurred_i &&
      resolved_control_flow_taken_i && incoming_rd_is_link_register &&
      ((resolved_control_flow_op_i == CF_JAL) || (resolved_control_flow_op_i == CF_JALR));
  assign incoming_return_stack_pop = resolved_control_flow_occurred_i &&
      resolved_control_flow_taken_i && incoming_return_instruction_present;

  always_comb begin
    return_stack_update_d           = '0;
    return_stack_update_d.return_pc =
        resolved_control_flow_pc_i + program_counter_t'(INSTRUCTION_BYTES);

    unique case ({incoming_return_stack_pop, incoming_return_stack_push})
      2'b01: return_stack_update_d.op = RETURN_STACK_UPDATE_PUSH;
      2'b10: return_stack_update_d.op = RETURN_STACK_UPDATE_POP;
      2'b11: return_stack_update_d.op = RETURN_STACK_UPDATE_POP_PUSH;
      default: return_stack_update_d.op = RETURN_STACK_UPDATE_NONE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      return_stack_update_q <= '0;
    end else if (invalidate_i) begin
      return_stack_update_q <= '0;
    end else begin
      return_stack_update_q <= return_stack_update_d;
    end
  end

  always_comb begin
    unique case (resolved_control_flow_update_q.op)
      CF_BRANCH: resolved_branch_target_kind = TARGET_KIND_CONDITIONAL_BRANCH;
      CF_JAL:    resolved_branch_target_kind = TARGET_KIND_DIRECT_JUMP;
      CF_JALR: begin
        resolved_branch_target_kind = resolved_return_instruction_present ?
                                      TARGET_KIND_RETURN : TARGET_KIND_INDIRECT_JUMP;
      end
      default:   resolved_branch_target_kind = TARGET_KIND_CONDITIONAL_BRANCH;
    endcase
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

  // 00/01预测不跳，10/11预测跳转。只用已解析条件分支训练方向，不让JAL/JALR
  // 污染方向历史。数组写入比控制流解析晚一拍；查询旁路让同索引请求看到本拍训练值。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned entry = 0; entry < BHT_ENTRY_COUNT; entry++) begin
        branch_history_counter_array_q[entry] <= 2'b01;
      end
    end else if (resolved_control_flow_update_q.present &&
                 (resolved_control_flow_update_q.op == CF_BRANCH)) begin
      branch_history_counter_array_q[resolved_branch_history_index] <=
          update_branch_history_counter(
          branch_history_counter_array_q[resolved_branch_history_index],
          resolved_control_flow_update_q.taken
      );
    end
  end

  // write_index指向下一次push位置，top位于write_index-1。更新使用已解析控制流，
  // 不需要为当前短流水线增加推测RAS checkpoint；未来扩大在途窗口时再引入恢复状态。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      return_stack_write_index_q <= '0;
      return_stack_entry_count_q <= '0;
      return_stack_top_pc_q      <= '0;
    end else if (invalidate_i) begin
      return_stack_write_index_q <= '0;
      return_stack_entry_count_q <= '0;
      return_stack_top_pc_q      <= '0;
    end else begin
      unique case (return_stack_update_q.op)
        RETURN_STACK_UPDATE_PUSH: begin
          return_stack_pc_array_q[return_stack_write_index_q] <=
              return_stack_update_q.return_pc;
          return_stack_write_index_q                          <= increment_return_stack_index(return_stack_write_index_q);
          return_stack_top_pc_q                               <= return_stack_update_q.return_pc;
          if (return_stack_entry_count_q != return_stack_count_t'(RAS_ENTRY_COUNT)) begin
            return_stack_entry_count_q <= return_stack_entry_count_q + return_stack_count_t'(1);
          end
        end

        RETURN_STACK_UPDATE_POP: begin
          if (return_stack_entry_count_q != '0) begin
            return_stack_write_index_q <= decrement_return_stack_index(return_stack_write_index_q);
            return_stack_entry_count_q <= return_stack_entry_count_q - return_stack_count_t'(1);
            if (return_stack_entry_count_q == return_stack_count_t'(1)) begin
              return_stack_top_pc_q <= '0;
            end else begin
              return_stack_top_pc_q <= return_stack_pc_array_q[
                  decrement_return_stack_index(decrement_return_stack_index(
                      return_stack_write_index_q
                  ))
              ];
            end
          end
        end

        RETURN_STACK_UPDATE_POP_PUSH: begin
          if (return_stack_entry_count_q != '0) begin
            return_stack_pc_array_q[return_stack_top_index] <=
                return_stack_update_q.return_pc;
            return_stack_top_pc_q <= return_stack_update_q.return_pc;
          end else begin
            return_stack_pc_array_q[return_stack_write_index_q] <=
                return_stack_update_q.return_pc;
            return_stack_write_index_q                          <= increment_return_stack_index(return_stack_write_index_q);
            return_stack_entry_count_q                          <= return_stack_count_t'(1);
            return_stack_top_pc_q                               <= return_stack_update_q.return_pc;
          end
        end

        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lookup_response_valid_o && lookup_prediction_o.predicted_taken) |->
      (lookup_next_pc_o == lookup_prediction_o.predicted_target &&
       (lookup_next_pc_o[1:0] == 2'b00)))
  else $error("fetch predictor emitted an invalid taken prediction");

  // 普通反压必须保持响应；显式flush则取消旧epoch事务，下一拍允许撤销valid。
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lookup_response_valid_o && !lookup_response_ready_i && !flush_lookup_i)
    |=> (flush_lookup_i ||
         (lookup_response_valid_o && $stable(lookup_prediction_o) &&
          $stable(lookup_next_pc_o))))
  else $error("fetch predictor changed its response while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    return_stack_entry_count_q <= return_stack_count_t'(RAS_ENTRY_COUNT))
  else $error("return-address stack entry count exceeded its capacity");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    lookup_query_present_q |-> $onehot0(lookup_branch_target_hit_way_vector))
  else $error("multiple BTB ways matched the same lookup PC");

`endif

endmodule
