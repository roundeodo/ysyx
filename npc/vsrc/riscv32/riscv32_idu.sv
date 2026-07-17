module riscv32_idu
  import riscv32_pkg::*;
(
    input  fetch_entry_t fetch_entry_i,
    input  logic         fetch_entry_valid_i,
    output logic         fetch_entry_ready_o,

    output decoded_uop_t decoded_uop_o,
    output logic         decoded_uop_valid_o,
    input  logic         decoded_uop_ready_i
);
  logic [31:0] instruction;
  logic [ 6:0] opcode;
  logic [ 4:0] rd_addr;
  logic [ 2:0] funct3;
  logic [ 4:0] rs1_addr;
  logic [ 4:0] rs2_addr;
  logic [ 6:0] funct7;
  logic [11:0] funct12;

  logic [31:0] i_type_imm;
  logic [31:0] s_type_imm;
  logic [31:0] b_type_imm;
  logic [31:0] u_type_imm;
  logic [31:0] j_type_imm;

  assign instruction = fetch_entry_i.instruction;
  assign opcode = instruction[6:0];
  assign rd_addr = instruction[11:7];
  assign funct3 = instruction[14:12];
  assign rs1_addr = instruction[19:15];
  assign rs2_addr = instruction[24:20];
  assign funct7 = instruction[31:25];
  assign funct12 = instruction[31:20];

  assign i_type_imm = {{20{instruction[31]}}, instruction[31:20]};
  assign s_type_imm = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
  assign b_type_imm = {
    {19{instruction[31]}},
    instruction[31],
    instruction[7],
    instruction[30:25],
    instruction[11:8],
    1'b0
  };
  assign u_type_imm = {instruction[31:12], 12'b0};
  assign j_type_imm = {
    {11{instruction[31]}},
    instruction[31],
    instruction[19:12],
    instruction[20],
    instruction[30:21],
    1'b0
  };

  assign fetch_entry_ready_o = decoded_uop_ready_i;
  assign decoded_uop_valid_o = fetch_entry_valid_i;

  // IDU is the only ISA-encoding decoder. Downstream modules consume semantic
  // operations and never inspect opcode/funct fields again.
  always_comb begin
    decoded_uop_o                 = '0;
    decoded_uop_o.pc              = fetch_entry_i.pc;
    decoded_uop_o.instruction     = instruction;
    decoded_uop_o.frontend_tag    = fetch_entry_i.frontend_tag;
    decoded_uop_o.prediction      = fetch_entry_i.prediction;
    decoded_uop_o.rs1             = rs1_addr;
    decoded_uop_o.rs2             = rs2_addr;
    decoded_uop_o.rd              = rd_addr;
    decoded_uop_o.int_ctrl.op     = ALU_ADD;
    decoded_uop_o.mem_ctrl.size   = MEM_SIZE_WORD;
    decoded_uop_o.exception_valid = fetch_entry_i.exception_valid;
    decoded_uop_o.exception_cause = fetch_entry_i.exception_cause;
    decoded_uop_o.exception_tval  = fetch_entry_i.exception_tval;

    unique case (opcode)
      OPCODE_R_TYPE: begin
        decoded_uop_o.fu_type                = FU_INT;
        decoded_uop_o.uses_rs1               = 1'b1;
        decoded_uop_o.uses_rs2               = 1'b1;
        decoded_uop_o.writes_rd              = (rd_addr != '0);
        decoded_uop_o.int_ctrl.operand_a_sel = OPA_RS1;
        decoded_uop_o.int_ctrl.operand_b_sel = OPB_RS2;

        unique case (funct3)
          FUNCT3_ADD_SUB: begin
            if (funct7 == FUNCT7_BASE) begin
              decoded_uop_o.int_ctrl.op = ALU_ADD;
            end else if (funct7 == FUNCT7_ALT) begin
              decoded_uop_o.int_ctrl.op = ALU_SUB;
            end else begin
              decoded_uop_o.exception_valid = 1'b1;
            end
          end
          FUNCT3_SLL: begin
            decoded_uop_o.int_ctrl.op = ALU_SLL;
            if (funct7 != FUNCT7_BASE) decoded_uop_o.exception_valid = 1'b1;
          end
          FUNCT3_SLT: begin
            decoded_uop_o.int_ctrl.op = ALU_SLT;
            if (funct7 != FUNCT7_BASE) decoded_uop_o.exception_valid = 1'b1;
          end
          FUNCT3_SLTU: begin
            decoded_uop_o.int_ctrl.op = ALU_SLTU;
            if (funct7 != FUNCT7_BASE) decoded_uop_o.exception_valid = 1'b1;
          end
          FUNCT3_XOR: begin
            decoded_uop_o.int_ctrl.op = ALU_XOR;
            if (funct7 != FUNCT7_BASE) decoded_uop_o.exception_valid = 1'b1;
          end
          FUNCT3_SRL_SRA: begin
            if (funct7 == FUNCT7_BASE) begin
              decoded_uop_o.int_ctrl.op = ALU_SRL;
            end else if (funct7 == FUNCT7_ALT) begin
              decoded_uop_o.int_ctrl.op = ALU_SRA;
            end else begin
              decoded_uop_o.exception_valid = 1'b1;
            end
          end
          FUNCT3_OR: begin
            decoded_uop_o.int_ctrl.op = ALU_OR;
            if (funct7 != FUNCT7_BASE) decoded_uop_o.exception_valid = 1'b1;
          end
          FUNCT3_AND: begin
            decoded_uop_o.int_ctrl.op = ALU_AND;
            if (funct7 != FUNCT7_BASE) decoded_uop_o.exception_valid = 1'b1;
          end
          default: decoded_uop_o.exception_valid = 1'b1;
        endcase
      end

      OPCODE_I_TYPE: begin
        decoded_uop_o.fu_type                = FU_INT;
        decoded_uop_o.uses_rs1               = 1'b1;
        decoded_uop_o.writes_rd              = (rd_addr != '0);
        decoded_uop_o.imm                    = i_type_imm;
        decoded_uop_o.int_ctrl.operand_a_sel = OPA_RS1;
        decoded_uop_o.int_ctrl.operand_b_sel = OPB_IMM;

        unique case (funct3)
          FUNCT3_ADD_SUB: decoded_uop_o.int_ctrl.op = ALU_ADD;
          FUNCT3_SLT:     decoded_uop_o.int_ctrl.op = ALU_SLT;
          FUNCT3_SLTU:    decoded_uop_o.int_ctrl.op = ALU_SLTU;
          FUNCT3_XOR:     decoded_uop_o.int_ctrl.op = ALU_XOR;
          FUNCT3_OR:      decoded_uop_o.int_ctrl.op = ALU_OR;
          FUNCT3_AND:     decoded_uop_o.int_ctrl.op = ALU_AND;
          FUNCT3_SLL: begin
            decoded_uop_o.int_ctrl.op = ALU_SLL;
            if (funct7 != FUNCT7_BASE) decoded_uop_o.exception_valid = 1'b1;
          end
          FUNCT3_SRL_SRA: begin
            if (funct7 == FUNCT7_BASE) begin
              decoded_uop_o.int_ctrl.op = ALU_SRL;
            end else if (funct7 == FUNCT7_ALT) begin
              decoded_uop_o.int_ctrl.op = ALU_SRA;
            end else begin
              decoded_uop_o.exception_valid = 1'b1;
            end
          end
          default:        decoded_uop_o.exception_valid = 1'b1;
        endcase
      end

      OPCODE_LUI: begin
        decoded_uop_o.fu_type                = FU_INT;
        decoded_uop_o.writes_rd              = (rd_addr != '0);
        decoded_uop_o.imm                    = u_type_imm;
        decoded_uop_o.int_ctrl.operand_a_sel = OPA_ZERO;
        decoded_uop_o.int_ctrl.operand_b_sel = OPB_IMM;
      end

      OPCODE_AUIPC: begin
        decoded_uop_o.fu_type                = FU_INT;
        decoded_uop_o.writes_rd              = (rd_addr != '0);
        decoded_uop_o.imm                    = u_type_imm;
        decoded_uop_o.int_ctrl.operand_a_sel = OPA_PC;
        decoded_uop_o.int_ctrl.operand_b_sel = OPB_IMM;
      end

      OPCODE_JAL: begin
        decoded_uop_o.fu_type        = FU_BRANCH;
        decoded_uop_o.writes_rd      = (rd_addr != '0);
        decoded_uop_o.imm            = j_type_imm;
        decoded_uop_o.branch_ctrl.op = CF_JAL;
      end

      OPCODE_JALR: begin
        decoded_uop_o.fu_type        = FU_BRANCH;
        decoded_uop_o.uses_rs1       = 1'b1;
        decoded_uop_o.writes_rd      = (rd_addr != '0);
        decoded_uop_o.imm            = i_type_imm;
        decoded_uop_o.branch_ctrl.op = CF_JALR;
        if (funct3 != 3'b000) decoded_uop_o.exception_valid = 1'b1;
      end

      OPCODE_BRANCH: begin
        decoded_uop_o.fu_type        = FU_BRANCH;
        decoded_uop_o.uses_rs1       = 1'b1;
        decoded_uop_o.uses_rs2       = 1'b1;
        decoded_uop_o.imm            = b_type_imm;
        decoded_uop_o.branch_ctrl.op = CF_BRANCH;
        unique case (funct3)
          FUNCT3_BEQ:  decoded_uop_o.branch_ctrl.condition = BR_BEQ;
          FUNCT3_BNE:  decoded_uop_o.branch_ctrl.condition = BR_BNE;
          FUNCT3_BLT:  decoded_uop_o.branch_ctrl.condition = BR_BLT;
          FUNCT3_BGE:  decoded_uop_o.branch_ctrl.condition = BR_BGE;
          FUNCT3_BLTU: decoded_uop_o.branch_ctrl.condition = BR_BLTU;
          FUNCT3_BGEU: decoded_uop_o.branch_ctrl.condition = BR_BGEU;
          default:     decoded_uop_o.exception_valid = 1'b1;
        endcase
      end

      OPCODE_LOAD: begin
        decoded_uop_o.fu_type                = FU_LSU;
        decoded_uop_o.uses_rs1               = 1'b1;
        decoded_uop_o.writes_rd              = (rd_addr != '0);
        decoded_uop_o.imm                    = i_type_imm;
        decoded_uop_o.int_ctrl.operand_a_sel = OPA_RS1;
        decoded_uop_o.int_ctrl.operand_b_sel = OPB_IMM;
        decoded_uop_o.mem_ctrl.cmd           = MEM_CMD_LOAD;
        unique case (funct3)
          FUNCT3_LB: begin
            decoded_uop_o.mem_ctrl.size          = MEM_SIZE_BYTE;
            decoded_uop_o.mem_ctrl.unsigned_load = 1'b0;
          end
          FUNCT3_LH: begin
            decoded_uop_o.mem_ctrl.size          = MEM_SIZE_HALF;
            decoded_uop_o.mem_ctrl.unsigned_load = 1'b0;
          end
          FUNCT3_LW: begin
            decoded_uop_o.mem_ctrl.size          = MEM_SIZE_WORD;
            decoded_uop_o.mem_ctrl.unsigned_load = 1'b0;
          end
          FUNCT3_LBU: begin
            decoded_uop_o.mem_ctrl.size          = MEM_SIZE_BYTE;
            decoded_uop_o.mem_ctrl.unsigned_load = 1'b1;
          end
          FUNCT3_LHU: begin
            decoded_uop_o.mem_ctrl.size          = MEM_SIZE_HALF;
            decoded_uop_o.mem_ctrl.unsigned_load = 1'b1;
          end
          default: decoded_uop_o.exception_valid = 1'b1;
        endcase
      end

      OPCODE_STORE: begin
        decoded_uop_o.fu_type                = FU_LSU;
        decoded_uop_o.uses_rs1               = 1'b1;
        decoded_uop_o.uses_rs2               = 1'b1;
        decoded_uop_o.imm                    = s_type_imm;
        decoded_uop_o.int_ctrl.operand_a_sel = OPA_RS1;
        decoded_uop_o.int_ctrl.operand_b_sel = OPB_IMM;
        decoded_uop_o.mem_ctrl.cmd           = MEM_CMD_STORE;
        unique case (funct3)
          FUNCT3_SB: decoded_uop_o.mem_ctrl.size = MEM_SIZE_BYTE;
          FUNCT3_SH: decoded_uop_o.mem_ctrl.size = MEM_SIZE_HALF;
          FUNCT3_SW: decoded_uop_o.mem_ctrl.size = MEM_SIZE_WORD;
          default:   decoded_uop_o.exception_valid = 1'b1;
        endcase
      end

      OPCODE_SYSTEM: begin
        decoded_uop_o.serializing = 1'b1;
        if (funct3 == FUNCT3_SYSTEM_PRIV) begin
          decoded_uop_o.fu_type = FU_SYSTEM;
          if ((rd_addr != '0) || (rs1_addr != '0)) begin
            decoded_uop_o.exception_valid = 1'b1;
          end else begin
            unique case (funct12)
              FUNCT12_ECALL: begin
                decoded_uop_o.system_op       = SYS_ECALL;
                decoded_uop_o.exception_valid = 1'b1;
                decoded_uop_o.exception_cause = EXC_ECALL_M;
              end
              FUNCT12_EBREAK: decoded_uop_o.system_op = SYS_EBREAK;
              FUNCT12_MRET:   decoded_uop_o.system_op = SYS_MRET;
              default:        decoded_uop_o.exception_valid = 1'b1;
            endcase
          end
        end else begin
          decoded_uop_o.fu_type          = FU_CSR;
          decoded_uop_o.csr_ctrl.addr    = funct12;
          decoded_uop_o.csr_ctrl.use_imm = funct3[2];
          decoded_uop_o.writes_rd        = (rd_addr != '0);

          unique case (funct3)
            FUNCT3_CSRRW, FUNCT3_CSRRWI: begin
              decoded_uop_o.csr_ctrl.op           = CSR_OP_RW;
              decoded_uop_o.csr_ctrl.read_enable  = (rd_addr != '0);
              decoded_uop_o.csr_ctrl.write_enable = 1'b1;
            end
            FUNCT3_CSRRS, FUNCT3_CSRRSI: begin
              decoded_uop_o.csr_ctrl.op           = CSR_OP_RS;
              decoded_uop_o.csr_ctrl.read_enable  = 1'b1;
              decoded_uop_o.csr_ctrl.write_enable = (rs1_addr != '0);
            end
            FUNCT3_CSRRC, FUNCT3_CSRRCI: begin
              decoded_uop_o.csr_ctrl.op           = CSR_OP_RC;
              decoded_uop_o.csr_ctrl.read_enable  = 1'b1;
              decoded_uop_o.csr_ctrl.write_enable = (rs1_addr != '0);
            end
            default: decoded_uop_o.exception_valid = 1'b1;
          endcase

          decoded_uop_o.uses_rs1 = !decoded_uop_o.csr_ctrl.use_imm && (rs1_addr != '0);
        end
      end

      OPCODE_MISC_MEM: begin
        decoded_uop_o.fu_type     = FU_SYSTEM;
        decoded_uop_o.serializing = 1'b1;
        unique case (funct3)
          3'b000:  decoded_uop_o.system_op = SYS_FENCE;
          3'b001:  decoded_uop_o.system_op = SYS_FENCE_I;
          default: decoded_uop_o.exception_valid = 1'b1;
        endcase
      end

      default: decoded_uop_o.exception_valid = 1'b1;
    endcase

    if (decoded_uop_o.exception_valid && !fetch_entry_i.exception_valid &&
        (decoded_uop_o.system_op != SYS_ECALL)) begin
      decoded_uop_o.exception_cause = EXC_ILLEGAL_INSTRUCTION;
      decoded_uop_o.exception_tval  = instruction;
    end

    // An excepting uop retains identity and cause metadata but cannot create any
    // younger-visible side effect before the trap boundary accepts it.
    if (decoded_uop_o.exception_valid) begin
      decoded_uop_o.fu_type               = FU_SYSTEM;
      decoded_uop_o.writes_rd             = 1'b0;
      decoded_uop_o.branch_ctrl           = '0;
      decoded_uop_o.mem_ctrl.cmd          = MEM_CMD_NONE;
      decoded_uop_o.csr_ctrl.write_enable = 1'b0;
    end
  end

  // NOTE(P4): when DECODE_WIDTH grows, keep this module as the stage boundary
  // and replicate a pure decode lane internally; ordering and backpressure stay here.

endmodule
