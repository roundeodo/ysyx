module riscv32_exu
  import riscv32_pkg::*;
(
    input  execute_packet_t execute_packet_i,
    input  logic            execute_valid_i,
    output logic            execute_ready_o,

    output execute_result_t direct_result_o,
    output logic            direct_valid_o,
    input  logic            direct_ready_i,

    output execute_result_t memory_result_o,
    output logic            memory_valid_o,
    input  logic            memory_ready_i
);
  logic            [XLEN-1:0] operand_a;
  logic            [XLEN-1:0] operand_b;
  logic            [XLEN-1:0] alu_result;
  logic            [XLEN-1:0] csr_operand;
  logic            [XLEN-1:0] csr_wdata;
  logic                       branch_condition;
  logic                       branch_taken;
  logic            [XLEN-1:0] branch_target;
  logic                       redirect_valid;
  execute_result_t            result;

  always_comb begin
    unique case (execute_packet_i.uop.int_ctrl.operand_a_sel)
      OPA_RS1: operand_a = execute_packet_i.rs1_value;
      OPA_PC:  operand_a = execute_packet_i.uop.pc;
      default: operand_a = '0;
    endcase

    unique case (execute_packet_i.uop.int_ctrl.operand_b_sel)
      OPB_RS2: operand_b = execute_packet_i.rs2_value;
      OPB_IMM: operand_b = execute_packet_i.uop.imm;
      default: operand_b = '0;
    endcase
  end

  always_comb begin
    unique case (execute_packet_i.uop.int_ctrl.op)
      ALU_ADD:  alu_result = operand_a + operand_b;
      ALU_SUB:  alu_result = operand_a - operand_b;
      ALU_SLL:  alu_result = operand_a << operand_b[4:0];
      ALU_SLT:  alu_result = {31'b0, $signed(operand_a) < $signed(operand_b)};
      ALU_SLTU: alu_result = {31'b0, operand_a < operand_b};
      ALU_XOR:  alu_result = operand_a ^ operand_b;
      ALU_SRL:  alu_result = operand_a >> operand_b[4:0];
      ALU_SRA:  alu_result = $signed(operand_a) >>> operand_b[4:0];
      ALU_OR:   alu_result = operand_a | operand_b;
      ALU_AND:  alu_result = operand_a & operand_b;
      default:  alu_result = '0;
    endcase
  end

  always_comb begin
    unique case (execute_packet_i.uop.branch_ctrl.condition)
      BR_BEQ: branch_condition = execute_packet_i.rs1_value == execute_packet_i.rs2_value;
      BR_BNE: branch_condition = execute_packet_i.rs1_value != execute_packet_i.rs2_value;
      BR_BLT:
      branch_condition = $signed(execute_packet_i.rs1_value) < $signed(execute_packet_i.rs2_value);
      BR_BGE:
      branch_condition = $signed(execute_packet_i.rs1_value) >= $signed(execute_packet_i.rs2_value);
      BR_BLTU: branch_condition = execute_packet_i.rs1_value < execute_packet_i.rs2_value;
      BR_BGEU: branch_condition = execute_packet_i.rs1_value >= execute_packet_i.rs2_value;
      default: branch_condition = 1'b0;
    endcase
  end

  always_comb begin
    branch_taken  = 1'b0;
    branch_target = '0;

    unique case (execute_packet_i.uop.branch_ctrl.op)
      CF_BRANCH: begin
        branch_taken  = branch_condition;
        branch_target = execute_packet_i.uop.pc + execute_packet_i.uop.imm;
      end
      CF_JAL: begin
        branch_taken  = 1'b1;
        branch_target = execute_packet_i.uop.pc + execute_packet_i.uop.imm;
      end
      CF_JALR: begin
        branch_taken  = 1'b1;
        branch_target = (execute_packet_i.rs1_value + execute_packet_i.uop.imm) & ~32'h1;
      end
      default: ;
    endcase
  end

  assign csr_operand = execute_packet_i.uop.csr_ctrl.use_imm ?
                       {{(XLEN-5){1'b0}}, execute_packet_i.uop.rs1} :
                       execute_packet_i.rs1_value;

  always_comb begin
    unique case (execute_packet_i.uop.csr_ctrl.op)
      CSR_OP_RW: csr_wdata = csr_operand;
      CSR_OP_RS: csr_wdata = execute_packet_i.csr_rdata | csr_operand;
      CSR_OP_RC: csr_wdata = execute_packet_i.csr_rdata & ~csr_operand;
      default:   csr_wdata = '0;
    endcase
  end

  assign redirect_valid = branch_taken && !execute_packet_i.uop.exception_valid;

  always_comb begin
    result                          = '0;
    result.uop                      = execute_packet_i.uop;
    result.result                   = alu_result;
    result.next_pc                  = execute_packet_i.uop.pc + 32'd4;
    result.csr_wdata                = csr_wdata;
    result.memory_addr              = alu_result;
    result.memory_wdata             = execute_packet_i.rs2_value;
    result.redirect_valid           = redirect_valid;
    result.redirect.target_pc       = branch_target;
    result.redirect.source_pc       = execute_packet_i.uop.pc;
    result.redirect.reason          = REDIRECT_BRANCH_MISPREDICT;
    result.redirect.flush_inclusive = 1'b0;

    if ((execute_packet_i.uop.fu_type == FU_CSR) && execute_packet_i.csr_illegal) begin
      result.uop.exception_valid       = 1'b1;
      result.uop.exception_cause       = EXC_ILLEGAL_INSTRUCTION;
      result.uop.exception_tval        = execute_packet_i.uop.instruction;
      result.uop.writes_rd             = 1'b0;
      result.uop.csr_ctrl.write_enable = 1'b0;
    end

    if (redirect_valid) begin
      result.next_pc = branch_target;
    end

    unique case (execute_packet_i.uop.fu_type)
      FU_BRANCH: result.result = execute_packet_i.uop.pc + 32'd4;
      FU_CSR:    result.result = execute_packet_i.csr_rdata;
      default:   ;
    endcase
  end

  assign direct_result_o = result;
  assign memory_result_o = result;

  assign direct_valid_o = execute_valid_i && (execute_packet_i.uop.fu_type != FU_LSU);
  assign memory_valid_o = execute_valid_i && (execute_packet_i.uop.fu_type == FU_LSU);
  assign execute_ready_o = (execute_packet_i.uop.fu_type == FU_LSU) ?
                           memory_ready_i : direct_ready_i;

  // NOTE(P5): split this aggregate into int_alu, branch_unit, agu, and csr_exec.
  // Each unit then receives a narrow request and emits an independent completion.

endmodule
