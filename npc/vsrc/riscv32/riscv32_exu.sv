module riscv32_exu
  import riscv32_pkg::*;
(
    input  execute_packet_t execute_packet_i,
    input  logic            execute_packet_valid_i,
    output logic            execute_packet_ready_o,

    output execute_result_t exu_result_o,
    output logic            exu_result_valid_o,
    input  logic            exu_result_ready_i,

    output lsu_req_t lsu_req_o,
    output logic     lsu_req_valid_o,
    input  logic     lsu_req_ready_i
);
  logic            [XLEN-1:0] operand_a;
  logic            [XLEN-1:0] operand_b;
  logic            [XLEN-1:0] alu_result;
  logic            [XLEN-1:0] csr_operand;
  logic            [XLEN-1:0] csr_wdata;
  logic                       branch_condition_met;
  logic                       branch_taken;
  logic            [XLEN-1:0] branch_target;
  logic                       branch_redirect_valid;
  execute_result_t            exu_result;

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
      BR_BEQ: branch_condition_met = execute_packet_i.rs1_value == execute_packet_i.rs2_value;
      BR_BNE: branch_condition_met = execute_packet_i.rs1_value != execute_packet_i.rs2_value;
      BR_BLT:
      branch_condition_met = $signed(execute_packet_i.rs1_value) <
          $signed(execute_packet_i.rs2_value);
      BR_BGE:
      branch_condition_met = $signed(execute_packet_i.rs1_value) >=
          $signed(execute_packet_i.rs2_value);
      BR_BLTU: branch_condition_met = execute_packet_i.rs1_value < execute_packet_i.rs2_value;
      BR_BGEU: branch_condition_met = execute_packet_i.rs1_value >= execute_packet_i.rs2_value;
      default: branch_condition_met = 1'b0;
    endcase
  end

  always_comb begin
    branch_taken  = 1'b0;
    branch_target = '0;

    unique case (execute_packet_i.uop.branch_ctrl.op)
      CF_BRANCH: begin
        branch_taken  = branch_condition_met;
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

  assign branch_redirect_valid = branch_taken && !execute_packet_i.uop.exception_valid;

  always_comb begin
    exu_result                              = '0;
    exu_result.uop                          = execute_packet_i.uop;
    exu_result.result                       = alu_result;
    exu_result.next_pc                      = execute_packet_i.uop.pc + 32'd4;
    exu_result.csr_wdata                    = csr_wdata;
    exu_result.redirect_valid               = branch_redirect_valid;
    exu_result.redirect_req.target_pc       = branch_target;
    exu_result.redirect_req.source_pc       = execute_packet_i.uop.pc;
    exu_result.redirect_req.reason          = REDIRECT_BRANCH_MISPREDICT;
    exu_result.redirect_req.flush_inclusive = 1'b0;

    if ((execute_packet_i.uop.fu_type == FU_CSR) && execute_packet_i.csr_illegal) begin
      exu_result.uop.exception_valid       = 1'b1;
      exu_result.uop.exception_cause       = EXC_ILLEGAL_INSTRUCTION;
      exu_result.uop.exception_tval        = execute_packet_i.uop.instruction;
      exu_result.uop.writes_rd             = 1'b0;
      exu_result.uop.csr_ctrl.write_enable = 1'b0;
    end

    if (branch_redirect_valid) begin
      exu_result.next_pc = branch_target;
    end

    unique case (execute_packet_i.uop.fu_type)
      FU_BRANCH: exu_result.result = execute_packet_i.uop.pc + 32'd4;
      FU_CSR:    exu_result.result = execute_packet_i.csr_rdata;
      default:   ;
    endcase
  end

  always_comb begin
    lsu_req_o                = '0;
    lsu_req_o.uop            = exu_result.uop;
    lsu_req_o.next_pc        = exu_result.next_pc;
    lsu_req_o.effective_addr = alu_result;
    lsu_req_o.store_data     = execute_packet_i.rs2_value;
  end

  assign exu_result_o = exu_result;
  assign exu_result_valid_o = execute_packet_valid_i && (execute_packet_i.uop.fu_type != FU_LSU);
  assign lsu_req_valid_o = execute_packet_valid_i && (execute_packet_i.uop.fu_type == FU_LSU);
  assign execute_packet_ready_o = (execute_packet_i.uop.fu_type == FU_LSU) ?
                                  lsu_req_ready_i : exu_result_ready_i;

  // NOTE(P5): split this aggregate into int_alu, branch_unit, agu, and csr_exec.
  // Each unit then receives a narrow request and emits an independent completion.

endmodule
