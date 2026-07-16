// contain some shared struct and variables for all modules
package riscv32_pkg;
  // ======
  // basic architecture parameter
  // ====== 
  parameter int XLEN = 32;

  // RISC-V 指令编码中的 rd/rs1/rs2 字段永远是 5 bit。
  // 即使 RV32E 只有 x0~x15，指令里寄存器字段仍然是 5 bit。
  parameter int ISA_REG_ADDR_W = 5;

  /* verilator lint_off UNUSEDPARAM */
  // RV32E 实际实现的架构寄存器数量是 16。
  // 如果 RegisterFile 内部数组只实现 16 个寄存器，内部索引最低 4 bit 就够。
  // 但是模块端口仍建议保留 5 bit，这样可以检测 x16~x31 非法使用。
  parameter int ARCH_REG_NUM = 16;
  parameter int ARCH_REG_IDX_W = 4;

  // reset vector
  parameter logic [XLEN-1:0] RESET_VECTOR = 32'h8000_0000;
  /* verilator lint_on UNUSEDPARAM */

  // ======
  // RISCV opcode definitions
  // ======
  localparam logic [6:0] OPCODE_LOAD     = 7'b0000011;  // lb/lh/lw/lbu/lhu
  localparam logic [6:0] OPCODE_MISC_MEM = 7'b0001111;  // fence
  localparam logic [6:0] OPCODE_I_TYPE   = 7'b0010011;  // addi/slti/.../srai
  localparam logic [6:0] OPCODE_AUIPC    = 7'b0010111;  // auipc
  localparam logic [6:0] OPCODE_STORE    = 7'b0100011;  // sb/sh/sw
  localparam logic [6:0] OPCODE_R_TYPE   = 7'b0110011;  // add/sub/sll/...
  localparam logic [6:0] OPCODE_LUI      = 7'b0110111;  // lui
  localparam logic [6:0] OPCODE_BRANCH   = 7'b1100011;  // beq/bne/blt/...
  localparam logic [6:0] OPCODE_JALR     = 7'b1100111;  // jalr
  localparam logic [6:0] OPCODE_JAL      = 7'b1101111;  // jal
  localparam logic [6:0] OPCODE_SYSTEM   = 7'b1110011;  // ecall/ebreak/csr

  // ======
  // funct3 definitions
  // ======

  // Branch funct3
  localparam logic [2:0] FUNCT3_BEQ  = 3'b000;
  localparam logic [2:0] FUNCT3_BNE  = 3'b001;
  localparam logic [2:0] FUNCT3_BLT  = 3'b100;
  localparam logic [2:0] FUNCT3_BGE  = 3'b101;
  localparam logic [2:0] FUNCT3_BLTU = 3'b110;
  localparam logic [2:0] FUNCT3_BGEU = 3'b111;

  // Load funct3
  localparam logic [2:0] FUNCT3_LB  = 3'b000;
  localparam logic [2:0] FUNCT3_LH  = 3'b001;
  localparam logic [2:0] FUNCT3_LW  = 3'b010;
  localparam logic [2:0] FUNCT3_LBU = 3'b100;
  localparam logic [2:0] FUNCT3_LHU = 3'b101;

  // Store funct3
  localparam logic [2:0] FUNCT3_SB = 3'b000;
  localparam logic [2:0] FUNCT3_SH = 3'b001;
  localparam logic [2:0] FUNCT3_SW = 3'b010;

  // ALU funct3
  localparam logic [2:0] FUNCT3_ADD_SUB = 3'b000;
  localparam logic [2:0] FUNCT3_SLL     = 3'b001;
  localparam logic [2:0] FUNCT3_SLT     = 3'b010;
  localparam logic [2:0] FUNCT3_SLTU    = 3'b011;
  localparam logic [2:0] FUNCT3_XOR     = 3'b100;
  localparam logic [2:0] FUNCT3_SRL_SRA = 3'b101;
  localparam logic [2:0] FUNCT3_OR      = 3'b110;
  localparam logic [2:0] FUNCT3_AND     = 3'b111;

  // ======
  // funct7 definitions
  // ======

  localparam logic [6:0] FUNCT7_BASE = 7'b0000000;
  localparam logic [6:0] FUNCT7_ALT  = 7'b0100000;  // sub/sra/srai

  // ======
  // system funct12 definitions
  // ecall  = 0x000
  // ebreak = 0x001
  //
  // 当前 NPC 只需要 ebreak 来结束仿真。
  // 后续如果支持异常/CSR，需要继续扩展这里。
  // ======
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [11:0] FUNCT12_ECALL = 12'h000;
  localparam logic [11:0] FUNCT12_MRET  = 12'h302;
  /* verilator lint_on UNUSEDPARAM */
  localparam logic [11:0] FUNCT12_EBREAK = 12'h001;

  // ======
  // immediate select
  //
  // Decoder 输出 imm_sel，后续由 IDU/top 根据 imm_sel 选择最终 immediate。
  //
  // 为什么要这么做：
  //   不希望 top.sv 里面再根据 opcode 重复写 immediate mux。
  //
  // 未来流水线：
  //   Decode 阶段可以直接生成 selected_imm，
  //   或者把 imm_sel 跟随指令送入 ID/EX pipeline register。
  // ======
  typedef enum logic [2:0] {
    IMM_NONE = 3'b000,
    IMM_I    = 3'b001,
    IMM_S    = 3'b010,
    IMM_B    = 3'b011,
    IMM_U    = 3'b100,
    IMM_J    = 3'b101
  } imm_sel_t;

  // ======
  // ALU source select
  // 当前单周期 CPU 仍然可以复用主 ALU 计算：
  //   普通 ALU 结果
  //   load/store 地址
  //   auipc 结果
  //   jal/branch target
  //
  // 未来高性能 CPU：
  //   branch target / jal target 可能会使用独立加法器，
  //   以减少主 ALU mux 规模和关键路径压力。
  // ======
  typedef enum logic [1:0] {
    ALU_SRC1_RS1  = 2'b00,
    ALU_SRC1_ZERO = 2'b01,
    ALU_SRC1_PC   = 2'b10
  } alu_src1_sel_t;

  typedef enum logic {
    ALU_SRC2_RS2 = 1'b0,
    ALU_SRC2_IMM = 1'b1
  } alu_src2_sel_t;

  // ======
  // ALU operation
  //
  // 高性能设计思想：
  //   Decode 阶段把 RISC-V 指令翻译成内部 alu_op。
  //   EXU 只执行 ALU_ADD / ALU_SUB / ALU_SLT 等内部操作，
  //   不再重复理解 opcode/funct3/funct7。
  //
  // 这就是从 ISA instruction 到 internal operation / micro-op 的第一步。
  // ======
  typedef enum logic [3:0] {
    ALU_ADD  = 4'b0000,
    ALU_SUB  = 4'b0001,
    ALU_SLL  = 4'b0010,
    ALU_SLT  = 4'b0011,
    ALU_SLTU = 4'b0100,
    ALU_XOR  = 4'b0101,
    ALU_SRL  = 4'b0110,
    ALU_SRA  = 4'b0111,
    ALU_OR   = 4'b1000,
    ALU_AND  = 4'b1001
  } alu_op_t;

  //======
  // Branch operation
  // branch_en 表示“这是 branch 指令”。
  // branch_op 表示具体 branch 条件。
  //
  // 未来高性能 CPU：
  //   branch_op 会和 branch metadata 一起进入分支预测、执行、
  //   mispredict recovery、flush/redirect 逻辑。
  // ======
  typedef enum logic [2:0] {
    BR_NONE = 3'b000,
    BR_BEQ  = 3'b001,
    BR_BNE  = 3'b010,
    BR_BLT  = 3'b011,
    BR_BGE  = 3'b100,
    BR_BLTU = 3'b101,
    BR_BGEU = 3'b110
  } branch_op_t;

  // ======
  // writeback select
  // WBU 不应该知道当前指令是 lw 还是 jal。
  // WBU 只应该根据 wb_sel 选择写回数据来源。
  // ======
  typedef enum logic [1:0] {
    WB_ALU_RES = 2'b00,
    WB_MEM_RES = 2'b01,
    WB_PC4     = 2'b10,
    WB_CSR     = 2'b11
  } wb_sel_t;

  // ======
  // Memory access size
  // ======
  typedef enum logic [1:0] {
    MEM_SIZE_BYTE = 2'b00,
    MEM_SIZE_HALF = 2'b01,
    MEM_SIZE_WORD = 2'b10
  } mem_size_t;

  // ======
  // memory command
  // 当前 Decoder 仍然可以输出 mem_ren / mem_wen。
  //
  // 但是从长期 SoC/高性能 CPU 设计看，LSU 更适合输出统一 memory request：
  //   mem_valid
  //   mem_cmd
  //   mem_addr
  //   mem_wdata
  //   mem_wmask
  //
  // 这里先定义 mem_cmd_t，为未来把 DPI memory 替换成 cache/bus 接口做准备。
  // ======

  typedef enum logic [1:0] {
    MEM_CMD_NONE  = 2'b00,
    MEM_CMD_LOAD  = 2'b01,
    MEM_CMD_STORE = 2'b10
  } mem_cmd_t;

  // ======
  // exception
  // 当前 stage 不一定马上实现异常系统。
  // 但是从 CPU/SoC 设计角度，illegal instruction 不能永远静默成 nop。
  //
  // 后续支持 CSR/trap 时，可以扩展这里。
  // ======
  typedef enum logic [3:0] {
    EXC_NONE           = 4'd0,
    EXC_ILLEGAL_INST   = 4'd2,
    EXC_BREAKPOINT     = 4'd3,
    EXC_LOAD_MISALIGN  = 4'd4,
    EXC_STORE_MISALIGN = 4'd6,
    EXC_ECALL_M        = 4'd11
  } exception_cause_t;

  // EXU result bundle
  //
  // 这是 EXU 对后级的结构化结果契约。当前可以直接用于 EXU->LSU/top，
  // 未来也可以作为 EX/MEM pipeline register、bypass source、ROB writeback
  // record 的基础字段集合。
  typedef struct packed {
    logic                      valid;
    logic [XLEN-1:0]           alu_res;
    logic [XLEN-1:0]           pc_plus_4;
    logic                      redirect_valid;
    logic [XLEN-1:0]           redirect_pc;
    logic [XLEN-1:0]           store_data;
    logic [ISA_REG_ADDR_W-1:0] rd_addr;
    mem_cmd_t                  mem_cmd;
    mem_size_t                 mem_size;
    logic                      mem_unsigned;
    wb_sel_t                   wb_sel;
    logic                      reg_wen;
  } ex_result_t;

  // LSU result bundle
  //
  // LSU -> WBU 也使用结构化 completion record，不退回散线。
  // 当前 C2 只需要这些字段供 WBU 选择写回数据；后续高性能 LSU 可继续扩展
  // exception_valid、exception_cause、badaddr、replay、rob_idx、physical_rd、
  // load_queue_idx、store_queue_idx 等字段。
  //
  // 高性能 CPU 关联：
  //   load miss、memory replay、store/load ordering violation 都需要 LSU 产生
  //   结构化 completion record。WBU/ROB/bypass 不应该从散线拼执行结果。
  typedef struct packed {
    logic                      valid;
    logic [XLEN-1:0]           alu_res;
    logic [XLEN-1:0]           mem_rdata;
    logic [XLEN-1:0]           pc_plus_4;
    logic [ISA_REG_ADDR_W-1:0] rd_addr;
    wb_sel_t                   wb_sel;
    logic                      reg_wen;
  } lsu_result_t;

  // CSR related
  typedef enum logic [1:0] {
    CSR_OP_NONE = 2'b00,
    CSR_OP_RW   = 2'b01,
    CSR_OP_RS   = 2'b10,
    CSR_OP_RC   = 2'b11
  } csr_op_t;


  // ======
  // decode control bundle
  // 这是给未来流水线/乱序设计准备的控制信息集合。
  //
  // 当前阶段：
  //   Decoder 已经直接输出 decode_ctrl_t ctrl；
  //   top/EXU/LSU/WBU 应该消费这个 bundle 的字段，而不是重新 decode opcode。
  //
  // 未来阶段：
  //   ID/EX pipeline register 可以直接保存这个 bundle；
  //   Rename/Dispatch 阶段也可以基于这个 bundle 生成更像 micro-op 的信息。
  //
  // 这体现的是高性能 CPU 的核心思想：
  //   ISA 指令在 Decode 阶段被翻译成内部控制信息；
  //   后端执行单元只消费内部控制信息，而不是重复解析 ISA。
  // ======
  typedef struct packed {
    logic             valid;
    imm_sel_t         imm_sel;
    alu_src1_sel_t    alu_src1_sel;
    alu_src2_sel_t    alu_src2_sel;
    alu_op_t          alu_op;
    branch_op_t       branch_op;
    logic             branch_en;
    logic             jal_en;
    logic             jalr_en;
    mem_cmd_t         mem_cmd;
    mem_size_t        mem_size;
    logic             mem_unsigned;
    wb_sel_t          wb_sel;
    logic             reg_wen;
    logic             ebreak_en;
    logic             illegal_instr;
    exception_cause_t exception_cause;
    csr_op_t          csr_op;
    logic             csr_ren;
    logic             csr_wren;
    logic             ecall_en;
    logic             mret_en;
  } decode_ctrl_t;


endpackage
