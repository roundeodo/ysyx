// 前端控制流预测器。
//
// 请求侧BTB/BHT/RAS在IFU发出I-cache请求时给出推测后继PC；响应侧只对无需读取GPR
// 即可确定目标的JAL、条件分支和标准ret进行冷启动纠正。最终执行结果仍由EX精确校验。
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

    input  program_counter_t                       lookup_pc_i,
    output branch_prediction_t                     lookup_prediction_o,
    output fetch_control_flow_prediction_context_t lookup_context_o,
    output program_counter_t                       lookup_next_pc_o,

    // I-cache响应返回后，只预译码能在没有寄存器值时确定后继PC的控制流。请求时保存的
    // BHT/RAS上下文保证响应被反压时输出保持稳定，不让训练更新改变valid payload。
    input  fetch_entry_t                           response_fetch_entry_i,
    input  fetch_control_flow_prediction_context_t response_context_i,
    input  logic                                   response_fetch_entry_valid_i,
    input  logic                                   response_fetch_entry_ready_i,
    output fetch_entry_t                           corrected_fetch_entry_o,
    output redirect_req_t                          fetch_correction_req_o,
    output logic                                   fetch_correction_req_valid_o,

    input program_counter_t resolved_control_flow_pc_i,
    input program_counter_t resolved_control_flow_target_i,
    input xlen_data_t       resolved_control_flow_imm_i,
    input control_flow_op_e resolved_control_flow_op_i,
    input arch_reg_idx_t    resolved_control_flow_rs1_i,
    input arch_reg_idx_t    resolved_control_flow_rd_i,
    input logic             resolved_control_flow_occurred_i,
    input logic             resolved_control_flow_taken_i,

    // fence.i使可能被软件改写的指令重新可见；保存旧控制流目标的BTB也必须同步失效。
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

  typedef struct packed {
    logic                  present;
    branch_history_index_t entry_index;
    logic                  branch_taken;
  } branch_history_update_t;

  branch_target_entry_t branch_target_entry_array_q[BTB_SET_COUNT][BTB_WAY_COUNT];
  branch_target_way_index_t branch_target_replacement_way_q[BTB_SET_COUNT];
  logic [1:0] branch_history_counter_array_q[BHT_ENTRY_COUNT];
  program_counter_t return_stack_pc_array_q[RAS_ENTRY_COUNT];

  branch_history_update_t branch_history_update_d;
  branch_history_update_t branch_history_update_q;

  branch_target_index_t lookup_branch_target_index;
  branch_target_tag_t lookup_branch_target_tag;
  branch_target_entry_t lookup_branch_target_entry;
  logic [BTB_WAY_COUNT-1:0] lookup_branch_target_hit_way_vector;
  logic lookup_branch_target_present;
  branch_history_index_t lookup_branch_history_index;
  logic [1:0] lookup_branch_history_counter;
  logic conditional_branch_predicted_taken;
  logic predicted_taken;
  program_counter_t predicted_target_pc;

  logic [6:0] response_opcode;
  logic [4:0] response_rd;
  logic [2:0] response_funct3;
  logic [4:0] response_rs1;
  xlen_data_t response_b_type_immediate;
  xlen_data_t response_i_type_immediate;
  xlen_data_t response_j_type_immediate;
  logic response_conditional_branch_present;
  logic response_direct_jump_present;
  logic response_return_present;
  branch_prediction_t response_corrected_prediction;
  program_counter_t response_sequential_pc;
  program_counter_t response_direct_target_pc;
  program_counter_t response_original_next_pc;
  program_counter_t response_corrected_next_pc;
  logic response_prediction_correction_needed;

  branch_target_index_t resolved_branch_target_index;
  branch_target_way_index_t resolved_branch_target_write_way;
  logic resolved_branch_target_hit_present;
  logic resolved_invalid_way_present;
  branch_target_tag_t resolved_branch_target_tag;
  branch_history_index_t resolved_branch_history_index;
  branch_target_kind_e resolved_branch_target_kind;
  logic resolved_rd_is_link_register;
  logic resolved_rs1_is_link_register;
  logic resolved_return_instruction_present;
  logic resolved_return_stack_push;
  logic resolved_return_stack_pop;

  return_stack_index_t return_stack_write_index_q;
  return_stack_index_t return_stack_top_index;
  return_stack_count_t return_stack_entry_count_q;
  program_counter_t return_stack_top_pc;

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

  function automatic logic branch_funct3_is_valid(input logic [2:0] funct3);
    unique case (funct3)
      3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111: return 1'b1;
      default:                                        return 1'b0;
    endcase
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

  // BTB使用PC低位选择set，并行比较set内各way的tag。两路组织相对同容量direct-map
  // 只增加一个tag比较器、选择器和每set一位替换状态，却能消除热点控制流的索引冲突。
  // 每个entry保存“哪个PC、属于哪类控制流、预测目标是什么”，不能只凭索引采用旧目标。
  assign lookup_branch_target_index = lookup_pc_i[BRANCH_TARGET_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )-1:$clog2(
      INSTRUCTION_BYTES
  )];
  assign lookup_branch_target_tag = lookup_pc_i[XLEN-1:BRANCH_TARGET_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )];
  always_comb begin
    lookup_branch_target_entry          = '0;
    lookup_branch_target_hit_way_vector = '0;
    for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
      if (branch_target_entry_array_q[lookup_branch_target_index][way_index].present &&
          (branch_target_entry_array_q[lookup_branch_target_index][way_index].pc_tag ==
           lookup_branch_target_tag)) begin
        lookup_branch_target_hit_way_vector[way_index] = 1'b1;
        lookup_branch_target_entry                     = 
                                                         branch_target_entry_array_q[lookup_branch_target_index][way_index];
      end
    end
    lookup_branch_target_present = |lookup_branch_target_hit_way_vector;
  end

  assign lookup_branch_history_index = lookup_pc_i[BRANCH_HISTORY_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )-1:$clog2(
      INSTRUCTION_BYTES
  )];

  // BHT训练请求先寄存一级，切断“EX控制流解析 -> BHT数组写口”的长组合路径。查询侧在
  // 索引相同时旁路尚未落入数组的训练结果，使连续访问同一BHT entry时仍看到最新状态。
  always_comb begin
    lookup_branch_history_counter = branch_history_counter_array_q[lookup_branch_history_index];
    if (branch_history_update_q.present &&
        (branch_history_update_q.entry_index == lookup_branch_history_index)) begin
      lookup_branch_history_counter = update_branch_history_counter(
          lookup_branch_history_counter, branch_history_update_q.branch_taken
      );
    end
  end
  assign conditional_branch_predicted_taken = lookup_branch_history_counter[1];

  assign return_stack_top_index = decrement_return_stack_index(return_stack_write_index_q);
  assign return_stack_top_pc = return_stack_pc_array_q[return_stack_top_index];

  always_comb begin
    lookup_context_o                                    = '0;
    lookup_context_o.conditional_branch_predicted_taken = conditional_branch_predicted_taken;
    lookup_context_o.return_target_present              = return_stack_entry_count_q != '0;
    lookup_context_o.return_target                      = return_stack_top_pc;
  end

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
          if (return_stack_entry_count_q != '0) begin
            predicted_target_pc = return_stack_top_pc;
          end
        end

        default: ;
      endcase
    end

    // 当前不支持C扩展，错误的2字节对齐目标不能作为有效预测送入前端。
    if (predicted_target_pc[1:0] != 2'b00) begin
      predicted_taken = 1'b0;
    end

    lookup_prediction_o                  = '0;
    lookup_prediction_o.predicted_taken  = predicted_taken;
    lookup_prediction_o.predicted_target = predicted_taken ? predicted_target_pc : '0;
    lookup_next_pc_o                     = predicted_taken ?
                                           predicted_target_pc :
                                           lookup_pc_i + program_counter_t'(INSTRUCTION_BYTES);
  end

  // 响应侧只处理无需读取GPR即可确定目标的控制流：JAL、条件分支和标准ret。一般
  // JALR的目标依赖rs1，仍使用请求侧BTB预测并由EX最终检查。这里不训练预测状态，
  // 只使用请求时冻结的BHT/RAS上下文，因此下游反压期间不会改变valid payload。
  assign response_opcode = response_fetch_entry_i.instruction[6:0];
  assign response_rd = response_fetch_entry_i.instruction[11:7];
  assign response_funct3 = response_fetch_entry_i.instruction[14:12];
  assign response_rs1 = response_fetch_entry_i.instruction[19:15];
  assign response_i_type_immediate = {
    {(XLEN - 12) {response_fetch_entry_i.instruction[31]}},
    response_fetch_entry_i.instruction[31:20]
  };
  assign response_b_type_immediate = {
    {(XLEN - 13) {response_fetch_entry_i.instruction[31]}},
    response_fetch_entry_i.instruction[31],
    response_fetch_entry_i.instruction[7],
    response_fetch_entry_i.instruction[30:25],
    response_fetch_entry_i.instruction[11:8],
    1'b0
  };
  assign response_j_type_immediate = {
    {(XLEN - 21) {response_fetch_entry_i.instruction[31]}},
    response_fetch_entry_i.instruction[31],
    response_fetch_entry_i.instruction[19:12],
    response_fetch_entry_i.instruction[20],
    response_fetch_entry_i.instruction[30:21],
    1'b0
  };

  assign response_conditional_branch_present =
      (response_opcode == OPCODE_BRANCH) && branch_funct3_is_valid(response_funct3);
  assign response_direct_jump_present = response_opcode == OPCODE_JAL;
  // 只把imm=0的JALR识别为标准return。x1/x5加非零偏移时，RAS栈顶不等于目标。
  assign response_return_present =
      (response_opcode == OPCODE_JALR) && (response_funct3 == 3'b000) &&
      is_link_register(arch_reg_idx_t'(response_rs1)) &&
      (!is_link_register(arch_reg_idx_t'(response_rd)) || (response_rd != response_rs1)) &&
      (response_i_type_immediate == '0);

  always_comb begin
    corrected_fetch_entry_o       = response_fetch_entry_i;
    response_corrected_prediction = response_fetch_entry_i.prediction;
    response_sequential_pc        = response_fetch_entry_i.pc +
                                    program_counter_t'(INSTRUCTION_BYTES);
    response_direct_target_pc     = '0;

    if (!response_fetch_entry_i.exception_valid) begin
      if (response_direct_jump_present) begin
        response_direct_target_pc = response_fetch_entry_i.pc +
                                    program_counter_t'(response_j_type_immediate);
        response_corrected_prediction.predicted_taken = response_direct_target_pc[1:0] == 2'b00;
        response_corrected_prediction.predicted_target =
            response_corrected_prediction.predicted_taken ? response_direct_target_pc : '0;
      end else if (response_conditional_branch_present) begin
        response_direct_target_pc = response_fetch_entry_i.pc +
                                    program_counter_t'(response_b_type_immediate);
        response_corrected_prediction.predicted_taken =
            response_context_i.conditional_branch_predicted_taken &&
            (response_direct_target_pc[1:0] == 2'b00);
        response_corrected_prediction.predicted_target =
            response_corrected_prediction.predicted_taken ? response_direct_target_pc : '0;
      end else if (response_return_present && response_context_i.return_target_present) begin
        response_corrected_prediction.predicted_taken =
            response_context_i.return_target[1:0] == 2'b00;
        response_corrected_prediction.predicted_target =
            response_corrected_prediction.predicted_taken ? response_context_i.return_target : '0;
      end
    end

    corrected_fetch_entry_o.prediction = response_corrected_prediction;
    response_original_next_pc = response_fetch_entry_i.prediction.predicted_taken ?
                                response_fetch_entry_i.prediction.predicted_target :
                                response_sequential_pc;
    response_corrected_next_pc = response_corrected_prediction.predicted_taken ?
                                 response_corrected_prediction.predicted_target :
                                 response_sequential_pc;
    response_prediction_correction_needed =
        response_corrected_next_pc != response_original_next_pc;

    fetch_correction_req_o                 = '0;
    fetch_correction_req_o.target_pc       = response_corrected_next_pc;
    fetch_correction_req_o.source_pc       = response_fetch_entry_i.pc;
    fetch_correction_req_o.flush_inclusive = 1'b0;
    fetch_correction_req_o.reason          = REDIRECT_FETCH_CORRECTION;
    // 纠正和当前entry进入fetch buffer必须是同一次握手。下游反压时不能提前改变epoch，
    // 否则尚未交付的当前指令会被误判为旧路径响应。
    fetch_correction_req_valid_o = response_fetch_entry_valid_i &&
                                   response_fetch_entry_ready_i &&
                                   response_prediction_correction_needed;
  end

  // 训练优先更新同PC的已有way，其次占用第一个invalid way；set已满时才采用本set的
  // round-robin替换位置。这样重复执行同一控制流不会制造重复entry，也不会无故推进替换状态。
  always_comb begin
    resolved_branch_target_write_way   = branch_target_replacement_way_q[
                                         resolved_branch_target_index
                                         ];
    resolved_branch_target_hit_present = 1'b0;
    resolved_invalid_way_present       = 1'b0;

    for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
      if (branch_target_entry_array_q[resolved_branch_target_index][way_index].present &&
          (branch_target_entry_array_q[resolved_branch_target_index][way_index].pc_tag ==
           resolved_branch_target_tag)) begin
        resolved_branch_target_write_way   = branch_target_way_index_t'(way_index);
        resolved_branch_target_hit_present = 1'b1;
      end else if (!branch_target_entry_array_q[resolved_branch_target_index][way_index].present &&
                   !resolved_invalid_way_present &&
                   !resolved_branch_target_hit_present) begin
        resolved_branch_target_write_way = branch_target_way_index_t'(way_index);
        resolved_invalid_way_present     = 1'b1;
      end
    end
  end

  assign resolved_branch_target_index = resolved_control_flow_pc_i[BRANCH_TARGET_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )-1:$clog2(
      INSTRUCTION_BYTES
  )];
  assign resolved_branch_target_tag =
      resolved_control_flow_pc_i[XLEN-1:
                                 BRANCH_TARGET_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )];
  assign resolved_branch_history_index =
      resolved_control_flow_pc_i[BRANCH_HISTORY_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )-1:$clog2(
      INSTRUCTION_BYTES
  )];

  always_comb begin
    branch_history_update_d              = '0;
    branch_history_update_d.present      = resolved_control_flow_occurred_i &&
                                           (resolved_control_flow_op_i == CF_BRANCH);
    branch_history_update_d.entry_index  = resolved_branch_history_index;
    branch_history_update_d.branch_taken = resolved_control_flow_taken_i;
  end

  assign resolved_rd_is_link_register = is_link_register(resolved_control_flow_rd_i);
  assign resolved_rs1_is_link_register = is_link_register(resolved_control_flow_rs1_i);
  // RISC-V用x1/x5的rd/rs1组合向硬件提示call、return和协程式pop+push。
  assign resolved_return_instruction_present =
      (resolved_control_flow_op_i == CF_JALR) && resolved_rs1_is_link_register &&
      (!resolved_rd_is_link_register ||
       (resolved_control_flow_rd_i != resolved_control_flow_rs1_i)) &&
      (resolved_control_flow_imm_i == '0);
  assign resolved_return_stack_push = resolved_control_flow_occurred_i &&
      resolved_control_flow_taken_i && resolved_rd_is_link_register &&
      ((resolved_control_flow_op_i == CF_JAL) ||
       (resolved_control_flow_op_i == CF_JALR));
  assign resolved_return_stack_pop = resolved_control_flow_occurred_i &&
      resolved_control_flow_taken_i && resolved_return_instruction_present;

  always_comb begin
    unique case (resolved_control_flow_op_i)
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
    end else if (resolved_control_flow_occurred_i) begin
      branch_target_entry_array_q[resolved_branch_target_index][
          resolved_branch_target_write_way
      ].present <= 1'b1;
      branch_target_entry_array_q[resolved_branch_target_index][
          resolved_branch_target_write_way
      ].pc_tag <=
          resolved_branch_target_tag;
      branch_target_entry_array_q[resolved_branch_target_index][
          resolved_branch_target_write_way
      ].target_pc <=
          resolved_control_flow_target_i;
      branch_target_entry_array_q[resolved_branch_target_index][
          resolved_branch_target_write_way
      ].kind <=
          resolved_branch_target_kind;

      if (!resolved_branch_target_hit_present && !resolved_invalid_way_present) begin
        branch_target_replacement_way_q[resolved_branch_target_index] <=
            (resolved_branch_target_write_way ==
             branch_target_way_index_t'(BTB_WAY_COUNT - 1)) ?
            '0 : resolved_branch_target_write_way + branch_target_way_index_t'(1);
      end
    end
  end

  // 训练流水寄存器只保存BHT写口需要的信息。它可以每拍接收一次更新，不降低连续分支
  // 的训练吞吐；BTB和RAS仍在解析周期更新，因为它们不在当前最慢的BHT写入路径上。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      branch_history_update_q <= '0;
    end else begin
      branch_history_update_q <= branch_history_update_d;
    end
  end

  // 00/01预测不跳，10/11预测跳转。只用已解析条件分支训练方向，不让JAL/JALR
  // 污染方向历史。数组写入比控制流解析晚一拍，查询旁路保持预测状态的可见时序不变。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned entry = 0; entry < BHT_ENTRY_COUNT; entry++) begin
        branch_history_counter_array_q[entry] <= 2'b01;
      end
    end else if (branch_history_update_q.present) begin
      branch_history_counter_array_q[branch_history_update_q.entry_index] <=
          update_branch_history_counter(
          branch_history_counter_array_q[branch_history_update_q.entry_index],
          branch_history_update_q.branch_taken
      );
    end
  end

  // write_index指向下一次push位置，top位于write_index-1。更新使用已解析控制流，
  // 不需要为当前短流水线增加推测RAS checkpoint；未来扩大在途窗口时再引入恢复状态。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      return_stack_write_index_q <= '0;
      return_stack_entry_count_q <= '0;
    end else if (invalidate_i) begin
      return_stack_write_index_q <= '0;
      return_stack_entry_count_q <= '0;
    end else begin
      unique case ({
        resolved_return_stack_pop, resolved_return_stack_push
      })
        2'b01: begin
          return_stack_pc_array_q[return_stack_write_index_q] <= 
                                                                 resolved_control_flow_pc_i + program_counter_t'(INSTRUCTION_BYTES);
          return_stack_write_index_q                          <= increment_return_stack_index(return_stack_write_index_q);
          if (return_stack_entry_count_q != return_stack_count_t'(RAS_ENTRY_COUNT)) begin
            return_stack_entry_count_q <= return_stack_entry_count_q + return_stack_count_t'(1);
          end
        end

        2'b10: begin
          if (return_stack_entry_count_q != '0) begin
            return_stack_write_index_q <= decrement_return_stack_index(return_stack_write_index_q);
            return_stack_entry_count_q <= return_stack_entry_count_q - return_stack_count_t'(1);
          end
        end

        2'b11: begin
          if (return_stack_entry_count_q != '0) begin
            return_stack_pc_array_q[return_stack_top_index] <=
                resolved_control_flow_pc_i + program_counter_t'(INSTRUCTION_BYTES);
          end else begin
            return_stack_pc_array_q[return_stack_write_index_q] <= 
                                                                   resolved_control_flow_pc_i + program_counter_t'(INSTRUCTION_BYTES);
            return_stack_write_index_q                          <= increment_return_stack_index(return_stack_write_index_q);
            return_stack_entry_count_q                          <= return_stack_count_t'(1);
          end
        end

        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    lookup_prediction_o.predicted_taken |->
      (lookup_next_pc_o == lookup_prediction_o.predicted_target &&
       (lookup_next_pc_o[1:0] == 2'b00)))
  else $error("fetch predictor emitted an invalid taken prediction");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    return_stack_entry_count_q <= return_stack_count_t'(RAS_ENTRY_COUNT))
  else $error("return-address stack entry count exceeded its capacity");

  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(
      lookup_branch_target_hit_way_vector
  ))
  else $error("multiple BTB ways matched the same lookup PC");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    fetch_correction_req_valid_o |->
      (response_fetch_entry_valid_i && response_fetch_entry_ready_i &&
       (fetch_correction_req_o.target_pc[1:0] == 2'b00)))
  else $error("fetch correction was emitted without a valid aligned response handshake");

`endif

endmodule
