// 前端控制流预测器。
//
// BTB/BHT/RAS与I-cache并行读取：请求握手时采样索引，下一拍给出预测结果。
// 预测器响应和对应I-cache响应必须原子交付；最终控制流结果仍由EX精确校验。
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
    input  logic               lookup_request_valid_i,
    output logic               lookup_request_ready_o,
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

  branch_target_entry_t branch_target_entry_array_q[BTB_SET_COUNT][BTB_WAY_COUNT];
  branch_target_way_index_t branch_target_replacement_way_q[BTB_SET_COUNT];
  logic [1:0] branch_history_counter_array_q[BHT_ENTRY_COUNT];
  program_counter_t return_stack_pc_array_q[RAS_ENTRY_COUNT];

  resolved_control_flow_update_t resolved_control_flow_update_q;

  // S0在请求握手沿读取预测数组，S1只比较已寄存的set内容。这样关键路径不再从
  // next-PC寄存器穿过BTB阵列和目标选择后反馈到同一寄存器。
  program_counter_t lookup_pc_q;
  branch_target_entry_t lookup_way_entry_array_q[BTB_WAY_COUNT];
  logic [1:0] lookup_branch_history_counter_q;
  logic lookup_return_target_present_q;
  program_counter_t lookup_return_target_q;
  logic lookup_response_valid_q;

  branch_target_index_t lookup_request_branch_target_index;
  branch_history_index_t lookup_request_branch_history_index;
  branch_target_tag_t lookup_branch_target_tag;
  branch_target_entry_t lookup_branch_target_entry;
  logic [BTB_WAY_COUNT-1:0] lookup_branch_target_hit_way_vector;
  logic lookup_branch_target_present;
  logic [1:0] lookup_branch_history_counter;
  logic conditional_branch_predicted_taken;
  logic predicted_taken;
  program_counter_t predicted_target_pc;

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

  assign lookup_request_ready_o = !lookup_response_valid_q || lookup_response_ready_i;
  assign lookup_response_valid_o = lookup_response_valid_q;

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

  // 预测请求和I-cache lookup在同一拍握手。BTB set、BHT counter和RAS栈顶在该时钟沿
  // 同时进入S1寄存器，因此预测查找不会增加I-cache命中延迟。响应被反压时，valid和
  // 所有预测payload保持不变；响应离开与新请求进入可以发生在同一拍，吞吐为一拍一条。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lookup_pc_q                    <= '0;
      lookup_branch_history_counter_q <= 2'b01;
      lookup_return_target_present_q <= 1'b0;
      lookup_return_target_q         <= '0;
      lookup_response_valid_q        <= 1'b0;
      for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
        lookup_way_entry_array_q[way_index] <= '0;
      end
    end else if (lookup_request_ready_o) begin
      lookup_response_valid_q <= lookup_request_valid_i;
      if (lookup_request_valid_i) begin
        lookup_pc_q <= lookup_request_pc_i;
        for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
          lookup_way_entry_array_q[way_index] <=
              branch_target_entry_array_q[lookup_request_branch_target_index][way_index];
        end
        lookup_branch_history_counter_q <=
            branch_history_counter_array_q[lookup_request_branch_history_index];
        // BHT写入晚于解析一级；同索引旁路保证请求在训练落入数组前看到最新方向状态。
        if (resolved_control_flow_update_q.present &&
            (resolved_control_flow_update_q.op == CF_BRANCH) &&
            (resolved_branch_history_index == lookup_request_branch_history_index)) begin
          lookup_branch_history_counter_q <= update_branch_history_counter(
              branch_history_counter_array_q[lookup_request_branch_history_index],
              resolved_control_flow_update_q.taken
          );
        end
        lookup_return_target_present_q <= return_stack_entry_count_q != '0;
        lookup_return_target_q         <= return_stack_top_pc;
      end
    end
  end

  // S1只比较已经寄存的一个BTB set。两路组织相对同容量direct-map只增加一个tag比较器、
  // 目标选择器和每set一位替换状态，却能显著减少热点控制流的索引冲突。
  assign lookup_branch_target_tag = lookup_pc_q[XLEN-1:BRANCH_TARGET_INDEX_WIDTH+$clog2(
      INSTRUCTION_BYTES
  )];
  always_comb begin
    lookup_branch_target_entry          = '0;
    lookup_branch_target_hit_way_vector = '0;
    for (int unsigned way_index = 0; way_index < BTB_WAY_COUNT; way_index++) begin
      if (lookup_way_entry_array_q[way_index].present &&
          (lookup_way_entry_array_q[way_index].pc_tag == lookup_branch_target_tag)) begin
        lookup_branch_target_hit_way_vector[way_index] = 1'b1;
        lookup_branch_target_entry                     = lookup_way_entry_array_q[way_index];
      end
    end
    lookup_branch_target_present = |lookup_branch_target_hit_way_vector;
  end

  assign lookup_branch_history_counter = lookup_branch_history_counter_q;
  assign conditional_branch_predicted_taken = lookup_branch_history_counter[1];

  assign return_stack_top_index = decrement_return_stack_index(return_stack_write_index_q);
  assign return_stack_top_pc = return_stack_pc_array_q[return_stack_top_index];

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
          if (lookup_return_target_present_q) begin
            predicted_target_pc = lookup_return_target_q;
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
                                           lookup_pc_q + program_counter_t'(INSTRUCTION_BYTES);
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

  assign resolved_rd_is_link_register = is_link_register(resolved_control_flow_update_q.rd);
  assign resolved_rs1_is_link_register = is_link_register(resolved_control_flow_update_q.rs1);
  // RISC-V用x1/x5的rd/rs1组合向硬件提示call、return和协程式pop+push。
  assign resolved_return_instruction_present =
      (resolved_control_flow_update_q.op == CF_JALR) && resolved_rs1_is_link_register &&
      (!resolved_rd_is_link_register ||
       (resolved_control_flow_update_q.rd != resolved_control_flow_update_q.rs1)) &&
      (resolved_control_flow_update_q.immediate == '0);
  assign resolved_return_stack_push = resolved_control_flow_update_q.present &&
      resolved_control_flow_update_q.taken && resolved_rd_is_link_register &&
      ((resolved_control_flow_update_q.op == CF_JAL) ||
       (resolved_control_flow_update_q.op == CF_JALR));
  assign resolved_return_stack_pop = resolved_control_flow_update_q.present &&
      resolved_control_flow_update_q.taken && resolved_return_instruction_present;

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
    end else if (resolved_control_flow_update_q.present) begin
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
          resolved_control_flow_update_q.target_pc;
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
    end else if (invalidate_i) begin
      return_stack_write_index_q <= '0;
      return_stack_entry_count_q <= '0;
    end else begin
      unique case ({
        resolved_return_stack_pop, resolved_return_stack_push
      })
        2'b01: begin
          return_stack_pc_array_q[return_stack_write_index_q] <= 
                                                                 resolved_control_flow_update_q.pc + program_counter_t'(INSTRUCTION_BYTES);
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
                resolved_control_flow_update_q.pc + program_counter_t'(INSTRUCTION_BYTES);
          end else begin
            return_stack_pc_array_q[return_stack_write_index_q] <= 
                                                                   resolved_control_flow_update_q.pc + program_counter_t'(INSTRUCTION_BYTES);
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
    (lookup_response_valid_o && lookup_prediction_o.predicted_taken) |->
      (lookup_next_pc_o == lookup_prediction_o.predicted_target &&
       (lookup_next_pc_o[1:0] == 2'b00)))
  else $error("fetch predictor emitted an invalid taken prediction");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lookup_response_valid_o && !lookup_response_ready_i)
    |=> (lookup_response_valid_o && $stable(lookup_prediction_o) &&
         $stable(lookup_next_pc_o)))
  else $error("fetch predictor changed its response while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    return_stack_entry_count_q <= return_stack_count_t'(RAS_ENTRY_COUNT))
  else $error("return-address stack entry count exceeded its capacity");

  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(
      lookup_branch_target_hit_way_vector
  ))
  else $error("multiple BTB ways matched the same lookup PC");

`endif

endmodule
