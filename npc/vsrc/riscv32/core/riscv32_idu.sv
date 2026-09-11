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
  // 指令编码固定为INSTR_WIDTH，而译码后的立即数必须先按指令格式形成，再扩展到XLEN。
  instruction_t instruction;
  logic [ 6:0] opcode;
  logic [ 4:0] rd_addr;
  logic [ 2:0] funct3;
  logic [ 4:0] rs1_addr;
  logic [ 4:0] rs2_addr;
  logic [ 5:0] funct6;
  logic [ 6:0] funct7;
  logic [11:0] funct12;

  xlen_data_t i_type_imm;
  xlen_data_t s_type_imm;
  xlen_data_t b_type_imm;
  xlen_data_t u_type_imm;
  xlen_data_t j_type_imm;

  assign instruction = fetch_entry_i.instruction;
  assign opcode = instruction[6:0];
  assign rd_addr = instruction[11:7];
  assign funct3 = instruction[14:12];
  assign rs1_addr = instruction[19:15];
  assign rs2_addr = instruction[24:20];
  assign funct6 = instruction[31:26];
  assign funct7 = instruction[31:25];
  assign funct12 = instruction[31:20];

  // RV64的LUI/AUIPC也要求将32位U立即数符号扩展到XLEN，不能简单在高位补零。
  assign i_type_imm = {{(XLEN - 12) {instruction[31]}}, instruction[31:20]};
  assign s_type_imm = {{(XLEN - 12) {instruction[31]}}, instruction[31:25], instruction[11:7]};
  assign b_type_imm = {
    {(XLEN - 13) {instruction[31]}},
    instruction[31],
    instruction[7],
    instruction[30:25],
    instruction[11:8],
    1'b0
  };
  assign u_type_imm = {{(XLEN - 32) {instruction[31]}}, instruction[31:12], 12'b0};
  assign j_type_imm = {
    {(XLEN - 21) {instruction[31]}},
    instruction[31],
    instruction[19:12],
    instruction[20],
    instruction[30:21],
    1'b0
  };

  assign fetch_entry_ready_o = decoded_uop_ready_i;
  assign decoded_uop_valid_o = fetch_entry_valid_i;

  // IDU是ISA编码的唯一译码所有者。下游只消费语义操作，不再检查opcode/funct字段。
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
      OPCODE_OP: begin
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

      OPCODE_OP_IMM: begin
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
            // RV64普通移位使用6位shamt，instruction[25]属于shamt而不是funct字段。
            // RV32仍使用完整funct7检查，从而拒绝shamt[5]=1的非法编码。
            if (XLEN == 64) begin
              if (funct6 != FUNCT6_BASE) decoded_uop_o.exception_valid = 1'b1;
            end else begin
              if (funct7 != FUNCT7_BASE) decoded_uop_o.exception_valid = 1'b1;
            end
          end
          FUNCT3_SRL_SRA: begin
            if (XLEN == 64) begin
              if (funct6 == FUNCT6_BASE) begin
                decoded_uop_o.int_ctrl.op = ALU_SRL;
              end else if (funct6 == FUNCT6_ALT) begin
                decoded_uop_o.int_ctrl.op = ALU_SRA;
              end else begin
                decoded_uop_o.exception_valid = 1'b1;
              end
            end else begin
              if (funct7 == FUNCT7_BASE) begin
                decoded_uop_o.int_ctrl.op = ALU_SRL;
              end else if (funct7 == FUNCT7_ALT) begin
                decoded_uop_o.int_ctrl.op = ALU_SRA;
              end else begin
                decoded_uop_o.exception_valid = 1'b1;
              end
            end
          end
          default:        decoded_uop_o.exception_valid = 1'b1;
        endcase
      end

      OPCODE_OP_IMM_32: begin
        decoded_uop_o.fu_type                = FU_INT;
        decoded_uop_o.uses_rs1               = 1'b1;
        decoded_uop_o.writes_rd              = (rd_addr != '0);
        decoded_uop_o.imm                    = i_type_imm;
        decoded_uop_o.int_ctrl.operand_a_sel = OPA_RS1;
        decoded_uop_o.int_ctrl.operand_b_sel = OPB_IMM;

        if (XLEN != 64) begin
          decoded_uop_o.exception_valid = 1'b1;
        end else begin
          unique case (funct3)
            FUNCT3_ADD_SUB: decoded_uop_o.int_ctrl.op = ALU_ADDW;
            FUNCT3_SLL: begin
              decoded_uop_o.int_ctrl.op = ALU_SLLW;
              // *IW只允许5位移位量，因此instruction[25]必须为0。
              if (funct7 != FUNCT7_BASE) decoded_uop_o.exception_valid = 1'b1;
            end
            FUNCT3_SRL_SRA: begin
              if (funct7 == FUNCT7_BASE) begin
                decoded_uop_o.int_ctrl.op = ALU_SRLW;
              end else if (funct7 == FUNCT7_ALT) begin
                decoded_uop_o.int_ctrl.op = ALU_SRAW;
              end else begin
                decoded_uop_o.exception_valid = 1'b1;
              end
            end
            default: decoded_uop_o.exception_valid = 1'b1;
          endcase
        end
      end

      OPCODE_OP_32: begin
        decoded_uop_o.fu_type                = FU_INT;
        decoded_uop_o.uses_rs1               = 1'b1;
        decoded_uop_o.uses_rs2               = 1'b1;
        decoded_uop_o.writes_rd              = (rd_addr != '0);
        decoded_uop_o.int_ctrl.operand_a_sel = OPA_RS1;
        decoded_uop_o.int_ctrl.operand_b_sel = OPB_RS2;

        if (XLEN != 64) begin
          decoded_uop_o.exception_valid = 1'b1;
        end else begin
          unique case (funct3)
            FUNCT3_ADD_SUB: begin
              if (funct7 == FUNCT7_BASE) begin
                decoded_uop_o.int_ctrl.op = ALU_ADDW;
              end else if (funct7 == FUNCT7_ALT) begin
                decoded_uop_o.int_ctrl.op = ALU_SUBW;
              end else begin
                decoded_uop_o.exception_valid = 1'b1;
              end
            end
            FUNCT3_SLL: begin
              decoded_uop_o.int_ctrl.op = ALU_SLLW;
              if (funct7 != FUNCT7_BASE) decoded_uop_o.exception_valid = 1'b1;
            end
            FUNCT3_SRL_SRA: begin
              if (funct7 == FUNCT7_BASE) begin
                decoded_uop_o.int_ctrl.op = ALU_SRLW;
              end else if (funct7 == FUNCT7_ALT) begin
                decoded_uop_o.int_ctrl.op = ALU_SRAW;
              end else begin
                decoded_uop_o.exception_valid = 1'b1;
              end
            end
            default: decoded_uop_o.exception_valid = 1'b1;
          endcase
        end
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
          FUNCT3_LD: begin
            decoded_uop_o.mem_ctrl.size          = MEM_SIZE_DOUBLE;
            decoded_uop_o.mem_ctrl.unsigned_load = 1'b0;
            if (XLEN != 64) decoded_uop_o.exception_valid = 1'b1;
          end
          FUNCT3_LBU: begin
            decoded_uop_o.mem_ctrl.size          = MEM_SIZE_BYTE;
            decoded_uop_o.mem_ctrl.unsigned_load = 1'b1;
          end
          FUNCT3_LHU: begin
            decoded_uop_o.mem_ctrl.size          = MEM_SIZE_HALF;
            decoded_uop_o.mem_ctrl.unsigned_load = 1'b1;
          end
          FUNCT3_LWU: begin
            decoded_uop_o.mem_ctrl.size          = MEM_SIZE_WORD;
            decoded_uop_o.mem_ctrl.unsigned_load = 1'b1;
            if (XLEN != 64) decoded_uop_o.exception_valid = 1'b1;
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
          FUNCT3_SD: begin
            decoded_uop_o.mem_ctrl.size = MEM_SIZE_DOUBLE;
            if (XLEN != 64) decoded_uop_o.exception_valid = 1'b1;
          end
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
                // 当前核只实现M-mode，因此ECALL的架构cause固定为11。加入U/S-mode后，
                // 应把当前特权级作为译码上下文输入，并在8、9、11之间选择。
                decoded_uop_o.exception_cause = EXC_ECALL_M;
                // ECALL不报告故障地址或故障指令，RISC-V规定mtval写零。
                decoded_uop_o.exception_tval  = '0;
              end
              FUNCT12_EBREAK: begin
                decoded_uop_o.system_op       = SYS_EBREAK;
                decoded_uop_o.exception_valid = 1'b1;
                decoded_uop_o.exception_cause = EXC_BREAKPOINT;
                decoded_uop_o.exception_tval  = '0;
              end
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

    // 同一条指令只保留最早阶段产生的异常。取指异常已经说明本条指令编码不可用，
    // IDU即使从返回数据位型中看到了ECALL/EBREAK，也不得覆盖IFU给出的cause和tval。
    if (fetch_entry_i.exception_valid) begin
      decoded_uop_o.exception_valid = 1'b1;
      decoded_uop_o.exception_cause = fetch_entry_i.exception_cause;
      decoded_uop_o.exception_tval  = fetch_entry_i.exception_tval;
    end else if (decoded_uop_o.exception_valid &&
                 (decoded_uop_o.system_op != SYS_ECALL) &&
                 (decoded_uop_o.system_op != SYS_EBREAK)) begin
      decoded_uop_o.exception_cause = EXC_ILLEGAL_INSTRUCTION;
      decoded_uop_o.exception_tval  = xlen_data_t'(instruction);
    end

    // 异常uop保留PC、指令和异常元数据，但在trap边界接收前不得产生架构副作用。
    if (decoded_uop_o.exception_valid) begin
      decoded_uop_o.fu_type               = FU_SYSTEM;
      decoded_uop_o.writes_rd             = 1'b0;
      decoded_uop_o.branch_ctrl           = '0;
      decoded_uop_o.mem_ctrl.cmd          = MEM_CMD_NONE;
      decoded_uop_o.csr_ctrl.write_enable = 1'b0;
    end
  end

  // NOTE(P4)：扩展DECODE_WIDTH时保留本模块作为阶段边界，在内部复制纯组合decode lane；
  // 顺序和反压仍由这个边界统一管理。

endmodule
