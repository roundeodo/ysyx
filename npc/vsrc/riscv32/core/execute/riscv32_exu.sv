module riscv32_exu
  import riscv32_pkg::*;
(
    input  logic            clk_i,
    input  logic            rst_ni,
    input  logic            flush_i,
    input  execute_packet_t execute_packet_i,
    input  logic [31:0]      multiply_operand_a_i,
    input  logic [31:0]      multiply_operand_b_i,
    input  logic            execute_packet_valid_i,
    // valid只表示ID/EX中存在payload；issue_allowed决定本拍是否允许这条指令离开EX。
    // 它既门控LSU副作用，也门控普通EXU completion，保证年轻整数/控制流指令不能
    // 越过仍在LSU中的老指令提交。恢复只清valid，不修改宽payload。
    input  logic execute_packet_issue_allowed_i,
    output logic execute_packet_ready_o,

    output execute_result_t exu_result_o,
    output logic            exu_result_valid_o,
    // 算术结果可用于前递；实际交付另受 valid/issue_allowed 保护。
    output logic            muldiv_result_available_o,
    output xlen_data_t       execute_forwarding_value_o,
    output logic             pipeline_busy_o,
    output execute_producer_t pipeline_producer_o [EXECUTE_PIPE_DEPTH],
    input  logic            exu_result_ready_i,

    output lsu_req_t lsu_req_o,
    output logic     lsu_req_valid_o,
    input  logic     lsu_req_ready_i,

    // 当前非分支交付时恢复顺序后继，覆盖普通执行与 LSU 两条路径。
    output redirect_req_t sequential_redirect_o,
    output logic          sequential_redirect_valid_o
);
  // EXU应只依赖ISA架构宽度；物理地址宽度和AXI数据宽度都不应进入ALU。这样将来把
  // 地址翻译放到AGU/MMU、把总线加宽时，不会迫使整数执行单元一起修改。
  localparam int unsigned SHIFT_AMOUNT_WIDTH = $clog2(XLEN);
  localparam int unsigned WORD_WIDTH = 32;
  localparam int unsigned WORD_SHIFT_WIDTH = $clog2(WORD_WIDTH);

  xlen_data_t execute_rs1_value;
  xlen_data_t execute_rs2_value;

  // operand_prepare 在消费者写入 ID/EX 时完成源选择与前递。EX 只消费寄存后的
  // 操作数，不再串联rd/rs比较、操作数选择或旁路mux。
  assign execute_rs1_value = execute_packet_i.source_a_value;
  assign execute_rs2_value = execute_packet_i.source_b_value;

  // 整数运算：主 ALU 与 32 位 word 运算并行，输出统一为 XLEN。
  xlen_data_t            alu_result;
  logic [WORD_WIDTH-1:0] word_result;

  // RV64的*W指令只在低32位中完成运算，再把32位结果符号扩展到XLEN。这里保留独立的
  // word-result通路，避免依赖宽位加法后的赋值截断，也明确约束寄存器型移位只使用
  // rs2[4:0]。因此rs2=32等价于移位0位，而非法的立即数shamt=32已由IDU拒绝。
  always_comb begin
    word_result = '0;
    unique case (execute_packet_i.uop.int_ctrl.op)
      ALU_ADDW: word_result = execute_rs1_value[WORD_WIDTH-1:0] + execute_rs2_value[WORD_WIDTH-1:0];
      ALU_SUBW: word_result = execute_rs1_value[WORD_WIDTH-1:0] - execute_rs2_value[WORD_WIDTH-1:0];
      ALU_SLLW:
        word_result = execute_rs1_value[WORD_WIDTH-1:0] << execute_rs2_value[WORD_SHIFT_WIDTH-1:0];
      ALU_SRLW:
        word_result = execute_rs1_value[WORD_WIDTH-1:0] >> execute_rs2_value[WORD_SHIFT_WIDTH-1:0];
      ALU_SRAW:
        word_result = $signed(execute_rs1_value[WORD_WIDTH-1:0]) >>>
          execute_rs2_value[WORD_SHIFT_WIDTH-1:0];
      default: word_result = '0;
    endcase
  end

  always_comb begin
    alu_result = '0;
    unique case (execute_packet_i.uop.int_ctrl.op)
      ALU_ADD: alu_result = execute_rs1_value + execute_rs2_value;
      ALU_SUB: alu_result = execute_rs1_value - execute_rs2_value;
      ALU_SLL: alu_result = execute_rs1_value << execute_rs2_value[SHIFT_AMOUNT_WIDTH-1:0];
      ALU_SLT: alu_result[0] = $signed(execute_rs1_value) < $signed(execute_rs2_value);
      ALU_SLTU: alu_result[0] = execute_rs1_value < execute_rs2_value;
      ALU_XOR: alu_result = execute_rs1_value ^ execute_rs2_value;
      ALU_SRL: alu_result = execute_rs1_value >> execute_rs2_value[SHIFT_AMOUNT_WIDTH-1:0];
      ALU_SRA:
        alu_result = $signed(execute_rs1_value) >>> execute_rs2_value[SHIFT_AMOUNT_WIDTH-1:0];
      ALU_OR: alu_result = execute_rs1_value | execute_rs2_value;
      ALU_AND: alu_result = execute_rs1_value & execute_rs2_value;
      ALU_ADDW, ALU_SUBW, ALU_SLLW, ALU_SRLW, ALU_SRAW:
        alu_result = {{(XLEN - WORD_WIDTH) {word_result[WORD_WIDTH-1]}}, word_result};
      default: alu_result = '0;
    endcase
  end

  // 乘法可进入独立流水；除法保留 ID/EX 操作数，最后一拍交付。
  logic muldiv_selected, multiply_selected, pipelined_multiply, multiply_shortcut;
  logic muldiv_result_available, iterative_available, iterative_ready;
  logic [31:0] muldiv_result, iterative_result;
  logic pipeline_request_ready;
  logic arithmetic_flush;
  assign muldiv_selected = MULDIV_ENABLE &&
      (execute_packet_i.uop.fu_type == FU_MULDIV) && !execute_packet_i.uop.exception_valid;
  assign multiply_selected = muldiv_selected &&
      (execute_packet_i.uop.muldiv_op <= MD_MULHU);
  assign pipelined_multiply = MUL_PIPELINE_ENABLE && multiply_selected;
  assign multiply_shortcut = (multiply_operand_a_i == '0) || (multiply_operand_b_i == '0);
  assign muldiv_result = pipelined_multiply ? 32'b0 : iterative_result;
  assign muldiv_result_available = pipelined_multiply ? multiply_shortcut : iterative_available;
  assign muldiv_result_available_o = execute_packet_valid_i && muldiv_selected &&
      muldiv_result_available;
  assign iterative_ready = MUL_PIPELINE_ENABLE ? pipeline_request_ready : exu_result_ready_i;
  // 结果端非分支纠错时，除法可能属于更年轻的 ID/EX，必须一起取消。
  assign arithmetic_flush = flush_i || (MUL_PIPELINE_ENABLE && sequential_redirect_valid_o);

  if (MUL_PIPELINE_ENABLE) begin : gen_div
    riscv32_div u_div (
        .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(arithmetic_flush),
        .operation_valid_i(execute_packet_valid_i && execute_packet_issue_allowed_i &&
                           muldiv_selected && !multiply_selected),
        .operation_i(execute_packet_i.uop.muldiv_op),
        .operand_a_i(execute_rs1_value[31:0]), .operand_b_i(execute_rs2_value[31:0]),
        .result_o(iterative_result), .result_available_o(iterative_available),
        .result_ready_i(iterative_ready)
    );
  end else if (MULDIV_ENABLE) begin : gen_muldiv
    riscv32_muldiv u_muldiv (
        .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
        .operation_valid_i(execute_packet_valid_i && execute_packet_issue_allowed_i && muldiv_selected),
        .operation_i(execute_packet_i.uop.muldiv_op),
        .operand_a_i(execute_rs1_value[31:0]), .operand_b_i(execute_rs2_value[31:0]),
        .result_o(iterative_result), .result_available_o(iterative_available),
        .result_ready_i(iterative_ready)
    );
  end else begin : gen_no_muldiv
    assign iterative_result = '0;
    assign iterative_available = 1'b0;
  end

  // load/store 与 JALR 都使用符号扩展的 12 位位移，共用地址加法。
  // IM 配置：低 12 位加法和高位传播条件并行，高位按进位保持或加/减一。
  // 原 I 配置保留已经测量的宽加法映射，避免共享修改使稳定配置时序退化。
  effective_addr_t base_offset_addr;
  if ((XLEN == 32) && MULDIV_ENABLE) begin : gen_rv32_address
    logic [12:0] offset_sum;
    logic [19:0] upper_propagate;
    logic        upper_adjust;

    // 三个 4 位组并行生成进位；低位不必逐位传播到第 12 位。
    logic [2:0] group_generate, group_propagate;
    logic [3:0] group_carry;
    assign group_carry[0] = 1'b0;
    assign group_carry[1] = group_generate[0];
    assign group_carry[2] = group_generate[1] |
                           (group_propagate[1] && group_generate[0]);
    assign group_carry[3] = group_generate[2] |
                           (group_propagate[2] && group_generate[1]) |
                           (group_propagate[2] && group_propagate[1] && group_generate[0]);
    for (genvar group_index = 0; group_index < 3; group_index++) begin : gen_offset_group
      logic [4:0] group_sum;
      assign group_sum = {1'b0, execute_rs1_value[group_index*4 +: 4]} +
                         {1'b0, execute_packet_i.uop.imm[group_index*4 +: 4]};
      assign group_generate[group_index] = group_sum[4];
      assign group_propagate[group_index] = &(execute_rs1_value[group_index*4 +: 4] |
                                              execute_packet_i.uop.imm[group_index*4 +: 4]);
      assign offset_sum[group_index*4 +: 4] = group_sum[3:0] +
                                            {3'b0, group_carry[group_index]};
    end
    assign offset_sum[12] = group_carry[3];
    assign upper_propagate = execute_rs1_value[31:12] ^
                             {20{execute_packet_i.uop.imm[11]}};
    assign upper_adjust = offset_sum[12] ^ execute_packet_i.uop.imm[11];
    assign base_offset_addr[11:0] = offset_sum[11:0];
    assign base_offset_addr[12] = execute_rs1_value[12] ^ upper_adjust;
    for (genvar bit_index = 13; bit_index < 32; bit_index++) begin : gen_upper_bit
      assign base_offset_addr[bit_index] = execute_rs1_value[bit_index] ^
          (upper_adjust && (&upper_propagate[bit_index-13:0]));
    end
  end else begin : gen_wide_address
    assign base_offset_addr = effective_addr_t'(execute_rs1_value + execute_packet_i.uop.imm);
  end

  // 控制流：比较 → 目标地址 → 实际后继与对齐检查。
  logic             branch_condition_met;
  logic             branch_taken;
  program_counter_t branch_target;
  program_counter_t sequential_next_pc;
  program_counter_t actual_next_pc;
  logic             branch_target_misaligned;

  always_comb begin
    unique case (execute_packet_i.uop.branch_ctrl.condition)
      BR_BEQ:  branch_condition_met = execute_rs1_value == execute_rs2_value;
      BR_BNE:  branch_condition_met = execute_rs1_value != execute_rs2_value;
      BR_BLT:  branch_condition_met = $signed(execute_rs1_value) < $signed(execute_rs2_value);
      BR_BGE:  branch_condition_met = $signed(execute_rs1_value) >= $signed(execute_rs2_value);
      BR_BLTU: branch_condition_met = execute_rs1_value < execute_rs2_value;
      BR_BGEU: branch_condition_met = execute_rs1_value >= execute_rs2_value;
      default: branch_condition_met = 1'b0;
    endcase
  end

  always_comb begin
    branch_taken  = 1'b0;
    branch_target = '0;

    unique case (execute_packet_i.uop.branch_ctrl.op)
      CF_BRANCH, CF_JAL: begin
        branch_taken  = (execute_packet_i.uop.branch_ctrl.op == CF_JAL) || branch_condition_met;
        branch_target = execute_packet_i.uop.pc + execute_packet_i.uop.imm;
      end
      CF_JALR: begin
        branch_taken = 1'b1;
        // JALR只规定目标地址bit 0清零，不规定实现必须是32位。
        branch_target = program_counter_t'(base_offset_addr);
        branch_target[0] = 1'b0;
      end
      default: ;
    endcase
  end

  // 基础RV32I/RV64I未实现C扩展，所有控制流目标都必须4字节对齐。
  assign sequential_next_pc       = execute_packet_i.uop.pc + program_counter_t'(INSTRUCTION_BYTES);
  assign actual_next_pc           = branch_taken ? branch_target : sequential_next_pc;
  assign branch_target_misaligned = branch_taken && (branch_target[1:0] != 2'b00);

  // CSR 读值由译码级提供，此处只计算写回值。
  xlen_data_t csr_operand;
  xlen_data_t csr_wdata;

  assign csr_operand = execute_packet_i.uop.csr_ctrl.use_imm ?
      {{(XLEN-5){1'b0}}, execute_packet_i.uop.rs1} :
      execute_rs1_value;

  always_comb begin
    unique case (execute_packet_i.uop.csr_ctrl.op)
      CSR_OP_RW: csr_wdata = csr_operand;
      CSR_OP_RS: csr_wdata = execute_packet_i.csr_rdata | csr_operand;
      CSR_OP_RC: csr_wdata = execute_packet_i.csr_rdata & ~csr_operand;
      default:   csr_wdata = '0;
    endcase
  end

  // 非访存结果汇合；异常指令在本出口撤销寄存器和 CSR 写副作用。
  execute_result_t exu_result;

  always_comb begin
    exu_result     = '0;
    exu_result.uop = execute_packet_i.uop;
    // 不要使用32'd4，也不要使用I-cache line/取指口宽度。顺序下一条指令的位置由ISA指令
    // 长度决定；cache一次返回多少字节属于前端微架构，两者必须解耦。
    exu_result.next_pc   = sequential_next_pc;
    exu_result.csr_wdata = csr_wdata;
    // 预测校验位于后继EX/MEM寄存级之后。本级只计算真实next_pc，避免把预测比较继续
    // 串在分支加法器之后。
    exu_result.redirect_valid = 1'b0;
    exu_result.redirect_req   = '0;

    if (!execute_packet_i.uop.exception_valid &&
        (execute_packet_i.uop.fu_type == FU_CSR) && execute_packet_i.csr_illegal) begin
      exu_result.uop.exception_valid       = 1'b1;
      exu_result.uop.exception_cause       = EXC_ILLEGAL_INSTRUCTION;
      exu_result.uop.exception_tval        = xlen_data_t'(execute_packet_i.uop.instruction);
      exu_result.uop.writes_rd             = 1'b0;
      exu_result.uop.csr_ctrl.write_enable = 1'b0;
    end

    if (!execute_packet_i.uop.exception_valid && branch_target_misaligned) begin
      exu_result.uop.exception_valid = 1'b1;
      exu_result.uop.exception_cause = EXC_INSTR_ADDR_MISALIGNED;
      exu_result.uop.exception_tval  = xlen_data_t'(branch_target);
      exu_result.uop.writes_rd       = 1'b0;
      exu_result.redirect_valid      = 1'b0;
    end

    if (execute_packet_i.uop.fu_type == FU_BRANCH) begin
      // next_pc始终记录真实架构后继；redirect只表示预测后继与它不一致。
      exu_result.next_pc = actual_next_pc;
    end

    unique case (execute_packet_i.uop.fu_type)
      FU_INT:  exu_result.result = alu_result;
      FU_BRANCH: begin
        exu_result.result = sequential_next_pc;
      end
      FU_CSR:  exu_result.result = execute_packet_i.csr_rdata;
      FU_MULDIV: exu_result.result = xlen_data_t'(muldiv_result);
      default: ;
    endcase
  end

  always_comb begin
    lsu_req_o                = '0;
    lsu_req_o.uop            = execute_packet_i.uop;
    lsu_req_o.next_pc        = sequential_next_pc;
    lsu_req_o.effective_addr = base_offset_addr;
    lsu_req_o.store_data     = execute_rs2_value;
  end

  // 算术前递对应当前 ID/EX；有序输出可能对应更老的乘法，二者不能混用。
  assign execute_forwarding_value_o = exu_result.result;
  logic input_result_valid;
  assign input_result_valid = execute_packet_valid_i &&
      (execute_packet_i.uop.fu_type != FU_LSU) &&
      (!muldiv_selected || muldiv_result_available || pipelined_multiply);

  if (MUL_PIPELINE_ENABLE) begin : gen_mul
    // EXU 保存顺序和指令身份；乘法器只保存部分积与压缩结果。
    logic [EXECUTE_PIPE_DEPTH-1:0] present_vector_q, multiply_vector_q;
    execute_result_t result_array_q [EXECUTE_PIPE_DEPTH];
    logic second_ready, first_ready, input_bypass, multiply_request;
    logic input_write, second_write, output_ready, output_valid;
    logic [63:0] product;
    xlen_data_t final_value;

    assign pipeline_busy_o = |present_vector_q;
    assign multiply_request = pipelined_multiply && !multiply_shortcut;
    assign input_bypass = !pipeline_busy_o && !multiply_request;
    assign output_ready = exu_result_ready_i && execute_packet_issue_allowed_i;
    assign second_ready = !present_vector_q[1] || output_ready;
    assign first_ready = !present_vector_q[0] || second_ready;
    // 接收能力独立于 issue_allowed。实际入队、出队仍由原许可严格门控。
    // issue_allowed 为真时，本式与原 first_ready/output_ready 完全一致；
    // 为假时不发生握手。整核 ID/EX 另受 progress 门控，恢复拍由 flush 清空。
    assign pipeline_request_ready = input_bypass ? exu_result_ready_i :
        (!present_vector_q[0] || !present_vector_q[1] || exu_result_ready_i);
    assign input_write = first_ready && execute_packet_issue_allowed_i &&
                         input_result_valid && !input_bypass;
    assign second_write = second_ready && present_vector_q[0];

    riscv32_mul u_mul (
        .clk_i                    (clk_i),
        .partial_products_write_i (input_write && multiply_request),
        .compressed_sum_write_i   (second_write && multiply_vector_q[0]),
        .operation_i              (execute_packet_i.uop.muldiv_op),
        .operand_a_i              (multiply_operand_a_i),
        .operand_b_i              (multiply_operand_b_i),
        .product_o                (product)
    );

    // 两组指令槽与乘法的两组内部寄存器同沿推进，不增加独立完成队列。
    always_ff @(posedge clk_i) begin
      if (input_write) begin
        result_array_q[0]   <= exu_result;
        multiply_vector_q[0] <= multiply_request;
      end
      if (second_write) begin
        result_array_q[1]   <= result_array_q[0];
        multiply_vector_q[1] <= multiply_vector_q[0];
      end
    end

    // 空槽或旧项推进时更新有效位；恢复只清有效位，宽载荷无需复位。
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni)
        present_vector_q <= '0;
      else if (arithmetic_flush)
        present_vector_q <= '0;
      else begin
        if (second_ready)
          present_vector_q[1] <= present_vector_q[0];
        if (first_ready)
          present_vector_q[0] <= input_write;
      end
    end

    // 普通结果随老乘法顺序推进；流水为空时普通结果和乘零直接交付。
    assign final_value = multiply_vector_q[1] ? xlen_data_t'(
        result_array_q[1].uop.muldiv_op == MD_MUL ? product[31:0] : product[63:32]) :
        result_array_q[1].result;
    always_comb begin
      exu_result_o        = result_array_q[1];
      exu_result_o.result = final_value;
      output_valid        = present_vector_q[1];
      if (input_bypass) begin
        exu_result_o = exu_result;
        output_valid = input_result_valid;
      end
    end
    assign exu_result_valid_o = output_valid && execute_packet_issue_allowed_i;

    // 第一级比第二级年轻。乘法在第二级组合相加后可前递，普通结果随时可前递。
    always_comb begin
      for (int i = 0; i < EXECUTE_PIPE_DEPTH; i++) begin
        pipeline_producer_o[i]             = '0;
        pipeline_producer_o[i].present     = present_vector_q[i];
        pipeline_producer_o[i].writes_rd   = result_array_q[i].uop.writes_rd;
        pipeline_producer_o[i].rd          = result_array_q[i].uop.rd;
        pipeline_producer_o[i].serializing = result_array_q[i].uop.serializing;
        pipeline_producer_o[i].forwardable = !result_array_q[i].uop.exception_valid &&
                                            ((i == 1) || !multiply_vector_q[i]);
        pipeline_producer_o[i].value       = (i == 1) ? final_value : result_array_q[i].result;
      end
    end

`ifndef SYNTHESIS
    /* verilator lint_off SYNCASYNCNET */
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      (output_valid && !output_ready && !arithmetic_flush) |=>
      (arithmetic_flush || (output_valid && $stable(exu_result_o))))
    else $error("EXU changed a stalled result");
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      arithmetic_flush |=> !pipeline_busy_o)
    else $error("EXU retained a flushed instruction");
    /* verilator lint_on SYNCASYNCNET */
`endif
  end else begin : gen_direct_result
    assign exu_result_o = exu_result;
    assign exu_result_valid_o = input_result_valid && execute_packet_issue_allowed_i;
    assign pipeline_request_ready = exu_result_ready_i;
    assign pipeline_busy_o = 1'b0;
    for (genvar i = 0; i < EXECUTE_PIPE_DEPTH; i++) begin : gen_no_producer
      assign pipeline_producer_o[i] = '0;
    end
  end

  // LSU 没有取消接口。所有更老执行项进入原结果级后，才允许年轻访存产生副作用。
  assign lsu_req_valid_o = execute_packet_valid_i && execute_packet_issue_allowed_i &&
      (execute_packet_i.uop.fu_type == FU_LSU) && !pipeline_busy_o;
  assign execute_packet_ready_o = (execute_packet_i.uop.fu_type == FU_LSU) ?
      (lsu_req_ready_i && !pipeline_busy_o) :
      (pipeline_request_ready && (!muldiv_selected || muldiv_result_available || pipelined_multiply));

  // 非分支错误 taken 在实际结果交付时纠错；不能在乘法入队时提前恢复。
  execute_result_t redirect_result;
  logic sequential_delivery;
  assign sequential_delivery = (exu_result_valid_o && exu_result_ready_i) ||
                               (lsu_req_valid_o && lsu_req_ready_i);
  always_comb begin
    redirect_result = exu_result_o;
    if (execute_packet_i.uop.fu_type == FU_LSU && !pipeline_busy_o)
      redirect_result = exu_result;
    sequential_redirect_o = '0;
    sequential_redirect_o.target_pc = redirect_result.next_pc;
    sequential_redirect_o.source_pc = redirect_result.uop.pc;
    sequential_redirect_o.reason = REDIRECT_NONBRANCH;
    sequential_redirect_o.flush_inclusive = 1'b0;
  end
  assign sequential_redirect_valid_o = sequential_delivery &&
      (redirect_result.uop.fu_type != FU_BRANCH) && !redirect_result.uop.exception_valid &&
      redirect_result.uop.prediction.predicted_taken &&
      (redirect_result.uop.prediction.predicted_target != redirect_result.next_pc);

`ifndef SYNTHESIS
  always_comb begin : check_exception_side_effects
    if (execute_packet_valid_i && !execute_packet_i.uop.exception_valid &&
        ((execute_packet_i.uop.fu_type == FU_LSU) ||
         (execute_packet_i.uop.branch_ctrl.op == CF_JALR))) begin
      assert (execute_packet_i.uop.imm ==
              {{(XLEN-12){execute_packet_i.uop.imm[11]}}, execute_packet_i.uop.imm[11:0]})
      else $error("Load/store or JALR immediate is not a sign-extended 12-bit offset");
    end

    if (exu_result_valid_o && exu_result_o.uop.exception_valid) begin
      assert (!exu_result_o.redirect_valid && !exu_result_o.uop.writes_rd)
      else
        $error("EXU exception retained a redirect or destination-register side effect");
    end

    if (execute_packet_valid_i && !execute_packet_issue_allowed_i) begin
      assert (!exu_result_valid_o && !lsu_req_valid_o)
      else
        $error("EXU emitted a completion while issue was blocked");
    end
  end
`endif

endmodule
