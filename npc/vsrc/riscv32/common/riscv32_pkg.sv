// Shared architectural constants, semantic enums, and inter-module payload types.
// This package is the only authority for core-wide contracts. Channel valid/ready
// signals and module-local state are intentionally kept outside these payloads.
package riscv32_pkg;

  // Architecture and microarchitecture configuration
  parameter int unsigned XLEN = 32;
  parameter int unsigned ARCH_REG_NUM = 32;

  // Width parameters remain 1 until the matching multi-lane hazards are verified.
  // Raising a width must not change payload semantics or module ownership.
  /* verilator lint_off UNUSEDPARAM */
  parameter int unsigned FETCH_WIDTH = 1;
  parameter int unsigned DECODE_WIDTH = 1;
  parameter int unsigned RENAME_WIDTH = 1;
  parameter int unsigned DISPATCH_WIDTH = 1;
  parameter int unsigned COMMIT_WIDTH = 1;
  parameter int unsigned INT_ISSUE_WIDTH = 1;
  parameter int unsigned MEM_ISSUE_WIDTH = 1;
  /* verilator lint_on UNUSEDPARAM */

  // Backend capacities are centralized here so rename, ROB, issue, and recovery
  // cannot silently use incompatible index widths.
  parameter int unsigned PHYS_REG_NUM = 64;
  parameter int unsigned ROB_ENTRIES = 32;
  parameter int unsigned LQ_ENTRIES = 16;
  parameter int unsigned SQ_ENTRIES = 16;
  parameter int unsigned MEM_TXN_ENTRIES = 16;
  parameter int unsigned FRONTEND_TAG_COUNT = 16;
  parameter int unsigned PREDICTOR_META_W = 32;

  localparam int unsigned ARCH_REG_IDX_W = (ARCH_REG_NUM > 1) ? $clog2(ARCH_REG_NUM) : 1;
  localparam int unsigned PHYS_REG_IDX_W = (PHYS_REG_NUM > 1) ? $clog2(PHYS_REG_NUM) : 1;
  localparam int unsigned ROB_IDX_W = (ROB_ENTRIES > 1) ? $clog2(ROB_ENTRIES) : 1;
  localparam int unsigned LQ_IDX_W = (LQ_ENTRIES > 1) ? $clog2(LQ_ENTRIES) : 1;
  localparam int unsigned SQ_IDX_W = (SQ_ENTRIES > 1) ? $clog2(SQ_ENTRIES) : 1;
  localparam int unsigned MEM_TXN_IDX_W = (MEM_TXN_ENTRIES > 1) ? $clog2(MEM_TXN_ENTRIES) : 1;
  localparam int unsigned FRONTEND_TAG_W = (FRONTEND_TAG_COUNT > 1) ? $clog2(
      FRONTEND_TAG_COUNT
  ) : 1;
  localparam int unsigned BYTE_LANES = XLEN / 8;

  /* verilator lint_off UNUSEDPARAM */
  parameter logic [XLEN-1:0] RESET_VECTOR = 32'h3000_0000;

  // ISA encoding constants
  // Only IDU/decode lanes may translate these encodings into semantic operations.
  localparam logic [6:0] OPCODE_LOAD     = 7'b0000011;
  localparam logic [6:0] OPCODE_MISC_MEM = 7'b0001111;
  localparam logic [6:0] OPCODE_I_TYPE   = 7'b0010011;
  localparam logic [6:0] OPCODE_AUIPC    = 7'b0010111;
  localparam logic [6:0] OPCODE_STORE    = 7'b0100011;
  localparam logic [6:0] OPCODE_R_TYPE   = 7'b0110011;
  localparam logic [6:0] OPCODE_LUI      = 7'b0110111;
  localparam logic [6:0] OPCODE_BRANCH   = 7'b1100011;
  localparam logic [6:0] OPCODE_JALR     = 7'b1100111;
  localparam logic [6:0] OPCODE_JAL      = 7'b1101111;
  localparam logic [6:0] OPCODE_SYSTEM   = 7'b1110011;

  localparam logic [2:0] FUNCT3_BEQ  = 3'b000;
  localparam logic [2:0] FUNCT3_BNE  = 3'b001;
  localparam logic [2:0] FUNCT3_BLT  = 3'b100;
  localparam logic [2:0] FUNCT3_BGE  = 3'b101;
  localparam logic [2:0] FUNCT3_BLTU = 3'b110;
  localparam logic [2:0] FUNCT3_BGEU = 3'b111;

  localparam logic [2:0] FUNCT3_LB  = 3'b000;
  localparam logic [2:0] FUNCT3_LH  = 3'b001;
  localparam logic [2:0] FUNCT3_LW  = 3'b010;
  localparam logic [2:0] FUNCT3_LBU = 3'b100;
  localparam logic [2:0] FUNCT3_LHU = 3'b101;

  localparam logic [2:0] FUNCT3_SB = 3'b000;
  localparam logic [2:0] FUNCT3_SH = 3'b001;
  localparam logic [2:0] FUNCT3_SW = 3'b010;

  localparam logic [2:0] FUNCT3_ADD_SUB = 3'b000;
  localparam logic [2:0] FUNCT3_SLL     = 3'b001;
  localparam logic [2:0] FUNCT3_SLT     = 3'b010;
  localparam logic [2:0] FUNCT3_SLTU    = 3'b011;
  localparam logic [2:0] FUNCT3_XOR     = 3'b100;
  localparam logic [2:0] FUNCT3_SRL_SRA = 3'b101;
  localparam logic [2:0] FUNCT3_OR      = 3'b110;
  localparam logic [2:0] FUNCT3_AND     = 3'b111;

  localparam logic [6:0] FUNCT7_BASE = 7'b0000000;
  localparam logic [6:0] FUNCT7_ALT  = 7'b0100000;

  localparam logic [2:0] FUNCT3_SYSTEM_PRIV = 3'b000;
  localparam logic [2:0] FUNCT3_CSRRW       = 3'b001;
  localparam logic [2:0] FUNCT3_CSRRS       = 3'b010;
  localparam logic [2:0] FUNCT3_CSRRC       = 3'b011;
  localparam logic [2:0] FUNCT3_CSRRWI      = 3'b101;
  localparam logic [2:0] FUNCT3_CSRRSI      = 3'b110;
  localparam logic [2:0] FUNCT3_CSRRCI      = 3'b111;

  localparam logic [11:0] FUNCT12_ECALL  = 12'h000;
  localparam logic [11:0] FUNCT12_EBREAK = 12'h001;
  localparam logic [11:0] FUNCT12_MRET   = 12'h302;

  /* verilator lint_on UNUSEDPARAM */

  // Canonical index types
  typedef logic [ARCH_REG_IDX_W-1:0] arch_reg_idx_t;
  typedef logic [PHYS_REG_IDX_W-1:0] phys_reg_idx_t;
  typedef logic [ROB_IDX_W-1:0] rob_idx_t;
  typedef logic [LQ_IDX_W-1:0] lq_idx_t;
  typedef logic [SQ_IDX_W-1:0] sq_idx_t;
  typedef logic [MEM_TXN_IDX_W-1:0] mem_txn_id_t;
  typedef logic [FRONTEND_TAG_W-1:0] frontend_tag_t;

  // Semantic operation enums
  // Zero is side-effect-free wherever possible so payload = '0 is a safe default.
  typedef enum logic [2:0] {
    FU_NONE   = 3'd0,
    FU_INT    = 3'd1,
    FU_BRANCH = 3'd2,
    FU_LSU    = 3'd3,
    FU_CSR    = 3'd4,
    FU_SYSTEM = 3'd5,
    FU_MULDIV = 3'd6
  } fu_type_e;

  typedef enum logic [1:0] {
    OPA_ZERO = 2'd0,
    OPA_RS1  = 2'd1,
    OPA_PC   = 2'd2
  } operand_a_sel_e;

  typedef enum logic [1:0] {
    OPB_ZERO = 2'd0,
    OPB_RS2  = 2'd1,
    OPB_IMM  = 2'd2
  } operand_b_sel_e;

  typedef enum logic [3:0] {
    ALU_ADD  = 4'd0,
    ALU_SUB  = 4'd1,
    ALU_SLL  = 4'd2,
    ALU_SLT  = 4'd3,
    ALU_SLTU = 4'd4,
    ALU_XOR  = 4'd5,
    ALU_SRL  = 4'd6,
    ALU_SRA  = 4'd7,
    ALU_OR   = 4'd8,
    ALU_AND  = 4'd9
  } alu_op_e;

  typedef enum logic [1:0] {
    CF_NONE   = 2'd0,
    CF_BRANCH = 2'd1,
    CF_JAL    = 2'd2,
    CF_JALR   = 2'd3
  } control_flow_op_e;

  typedef enum logic [2:0] {
    BR_NONE = 3'd0,
    BR_BEQ  = 3'd1,
    BR_BNE  = 3'd2,
    BR_BLT  = 3'd3,
    BR_BGE  = 3'd4,
    BR_BLTU = 3'd5,
    BR_BGEU = 3'd6
  } branch_cond_e;

  typedef enum logic [1:0] {
    MEM_CMD_NONE  = 2'd0,
    MEM_CMD_LOAD  = 2'd1,
    MEM_CMD_STORE = 2'd2
  } mem_cmd_e;

  typedef enum logic [1:0] {
    MEM_SIZE_BYTE = 2'd0,
    MEM_SIZE_HALF = 2'd1,
    MEM_SIZE_WORD = 2'd2
  } mem_size_e;

  typedef enum logic [1:0] {
    CSR_OP_NONE = 2'd0,
    CSR_OP_RW   = 2'd1,
    CSR_OP_RS   = 2'd2,
    CSR_OP_RC   = 2'd3
  } csr_op_e;

  typedef enum logic [2:0] {
    SYS_NONE    = 3'd0,
    SYS_ECALL   = 3'd1,
    SYS_EBREAK  = 3'd2,
    SYS_MRET    = 3'd3,
    SYS_FENCE   = 3'd4,
    SYS_FENCE_I = 3'd5
  } system_op_e;

  typedef enum logic [4:0] {
    EXC_INSTR_ADDR_MISALIGNED = 5'd0,
    EXC_INSTR_ACCESS_FAULT    = 5'd1,
    EXC_ILLEGAL_INSTRUCTION   = 5'd2,
    EXC_BREAKPOINT            = 5'd3,
    EXC_LOAD_ADDR_MISALIGNED  = 5'd4,
    EXC_LOAD_ACCESS_FAULT     = 5'd5,
    EXC_STORE_ADDR_MISALIGNED = 5'd6,
    EXC_STORE_ACCESS_FAULT    = 5'd7,
    EXC_ECALL_U               = 5'd8,
    EXC_ECALL_M               = 5'd11
  } exception_cause_e;

  typedef enum logic [3:0] {
    IRQ_MACHINE_SOFTWARE = 4'd3,
    IRQ_MACHINE_TIMER    = 4'd7,
    IRQ_MACHINE_EXTERNAL = 4'd11
  } interrupt_cause_e;

  typedef enum logic [2:0] {
    REDIRECT_NONE              = 3'd0,
    REDIRECT_BRANCH_MISPREDICT = 3'd1,
    REDIRECT_TRAP              = 3'd2,
    REDIRECT_MRET              = 3'd3,
    REDIRECT_MEMORY_REPLAY     = 3'd4,
    REDIRECT_DEBUG             = 3'd5
  } redirect_reason_e;

  typedef enum logic [1:0] {
    PRIV_MODE_U = 2'b00,
    PRIV_MODE_S = 2'b01,
    PRIV_MODE_M = 2'b11
  } priv_mode_e;

  // Decode control groups
  // decoded_uop_t carries all groups for regular lane wiring. Dedicated issue
  // payloads below remove unrelated groups before timing-critical backend paths.
  typedef struct packed {
    alu_op_e        op;
    operand_a_sel_e operand_a_sel;
    operand_b_sel_e operand_b_sel;
  } int_uop_ctrl_t;

  typedef struct packed {
    control_flow_op_e op;
    branch_cond_e     condition;
  } branch_uop_ctrl_t;

  typedef struct packed {
    mem_cmd_e  cmd;
    mem_size_e size;
    logic      unsigned_load;
  } mem_uop_ctrl_t;

  typedef struct packed {
    csr_op_e     op;
    logic [11:0] addr;
    logic        read_enable;
    logic        write_enable;
    logic        use_imm;
  } csr_uop_ctrl_t;

  // Frontend payloads
  // predictor_meta is opaque outside the predictor and branch-recovery path.
  typedef struct packed {
    logic                        predicted_taken;
    logic [XLEN-1:0]             predicted_target;
    logic [PREDICTOR_META_W-1:0] predictor_meta;
  } branch_prediction_t;

  typedef struct packed {
    logic [XLEN-1:0]    pc;
    logic [31:0]        instruction;
    frontend_tag_t      frontend_tag;
    branch_prediction_t prediction;
    logic               exception_valid;
    exception_cause_e   exception_cause;
    logic [XLEN-1:0]    exception_tval;
  } fetch_entry_t;

  // Decode and rename payloads
  // IDU is the only module that translates opcode/funct fields. All unused
  // control groups must be zeroed before the payload leaves IDU.
  typedef struct packed {
    logic [XLEN-1:0]    pc;
    logic [31:0]        instruction;
    frontend_tag_t      frontend_tag;
    branch_prediction_t prediction;

    arch_reg_idx_t rs1;
    arch_reg_idx_t rs2;
    arch_reg_idx_t rd;
    logic          uses_rs1;
    logic          uses_rs2;
    logic          writes_rd;

    fu_type_e         fu_type;
    logic [XLEN-1:0]  imm;
    int_uop_ctrl_t    int_ctrl;
    branch_uop_ctrl_t branch_ctrl;
    mem_uop_ctrl_t    mem_ctrl;
    csr_uop_ctrl_t    csr_ctrl;
    system_op_e       system_op;
    logic             serializing;

    logic             exception_valid;
    exception_cause_e exception_cause;
    logic [XLEN-1:0]  exception_tval;
  } decoded_uop_t;

  typedef struct packed {
    decoded_uop_t  uop;
    phys_reg_idx_t psrc1;
    phys_reg_idx_t psrc2;
    phys_reg_idx_t pdst;
    phys_reg_idx_t stale_pdst;
    rob_idx_t      rob_idx;
  } renamed_uop_t;

  // Redirect and execution payloads
  // rob_idx identifies instruction age. flush_inclusive distinguishes recovery
  // that keeps the source instruction from recovery that removes it as well.
  typedef struct packed {
    logic [XLEN-1:0]  target_pc;
    logic [XLEN-1:0]  source_pc;
    rob_idx_t         rob_idx;
    logic             rob_idx_valid;
    logic             flush_inclusive;
    redirect_reason_e reason;
  } redirect_req_t;

  typedef struct packed {
    alu_op_e         op;
    logic [XLEN-1:0] operand_a;
    logic [XLEN-1:0] operand_b;
    phys_reg_idx_t   pdst;
    rob_idx_t        rob_idx;
    logic            writes_preg;
  } int_execute_req_t;

  typedef struct packed {
    control_flow_op_e   op;
    branch_cond_e       condition;
    logic [XLEN-1:0]    pc;
    logic [XLEN-1:0]    imm;
    logic [XLEN-1:0]    src1_value;
    logic [XLEN-1:0]    src2_value;
    phys_reg_idx_t      pdst;
    rob_idx_t           rob_idx;
    logic               writes_preg;
    frontend_tag_t      frontend_tag;
    branch_prediction_t prediction;
  } branch_execute_req_t;

  typedef struct packed {
    mem_uop_ctrl_t   mem_ctrl;
    logic [XLEN-1:0] base_value;
    logic [XLEN-1:0] offset;
    logic [XLEN-1:0] store_data;
    phys_reg_idx_t   pdst;
    rob_idx_t        rob_idx;
    lq_idx_t         lq_idx;
    sq_idx_t         sq_idx;
    logic            lq_idx_valid;
    logic            sq_idx_valid;
    logic            writes_preg;
  } lsu_execute_req_t;

  typedef struct packed {
    csr_op_e         op;
    logic [11:0]     addr;
    logic [XLEN-1:0] operand;
    logic [XLEN-1:0] old_value;
    phys_reg_idx_t   pdst;
    rob_idx_t        rob_idx;
    logic            read_enable;
    logic            write_enable;
    logic            writes_preg;
  } csr_execute_req_t;

  // Every execution unit returns the same completion shape. This unifies PRF
  // writeback, wakeup, and ROB completion without making completion equal commit.
  typedef struct packed {
    rob_idx_t        rob_idx;
    logic            writes_preg;
    phys_reg_idx_t   pdst;
    logic [XLEN-1:0] result;

    logic            csr_write;
    logic [11:0]     csr_addr;
    logic [XLEN-1:0] csr_wdata;

    logic             exception_valid;
    exception_cause_e exception_cause;
    logic [XLEN-1:0]  exception_tval;

    logic          redirect_valid;
    redirect_req_t redirect_req;
    logic          replay;
  } completion_t;

  // TODO(AXI-PKG-TYPES): 在本TODO正下方先增加AXI4-Lite公共类型，再开始修改IFU/LSU端口。
  // 参考ARM IHI 0022H B1.1：Lite只有AR/R/AW/W/B五个独立通道，没有ID、LEN、
  // SIZE、BURST、LAST。不要把valid/ready放进payload struct，因为二者方向因master/slave
  // 而异，而且每个通道必须独立握手。
  // 当前XLEN=32满足Lite只允许32/64-bit数据宽度的要求。增加静态检查，防止以后把XLEN改成
  // 其他宽度后接口仍被误称为AXI4-Lite。AxPROT不要留X：当前可固定为secure访问；
  // IFU设置instruction属性，LSU设置data属性，privileged位由当前RISC-V特权级策略决定。
  typedef enum logic [1:0] {
    AXI_RESP_OKAY   = 2'b00,
    AXI_RESP_EXOKAY = 2'b01,
    AXI_RESP_SLVERR = 2'b10,
    AXI_RESP_DECERR = 2'b11
  } axi_resp_e;

  typedef struct packed {
    logic [XLEN-1:0] addr;
    logic [2:0]      prot;
  } axi_lite_addr_t;

  typedef struct packed {
    logic [XLEN-1:0]       data;
    logic [BYTE_LANES-1:0] strb;
  } axi_lite_w_t;

  typedef struct packed {axi_resp_e resp;} axi_lite_b_t;

  typedef struct packed {
    logic [XLEN-1:0] data;
    axi_resp_e       resp;
  } axi_lite_r_t;

  typedef struct packed {
    logic [XLEN-1:0] addr;
    logic [3:0]      id;
    logic [7:0]      len;
    logic [2:0]      size;
    logic [1:0]      burst;
  } axi_addr_t;

  typedef struct packed {
    logic [XLEN-1:0]       data;
    logic [BYTE_LANES-1:0] strb;
    logic                  last;
  } axi_w_t;

  typedef struct packed {
    axi_resp_e  resp;
    logic [3:0] id;
  } axi_b_t;

  typedef struct packed {
    axi_resp_e       resp;
    logic [XLEN-1:0] data;
    logic            last;
    logic [3:0]      id;
  } axi_r_t;






  // Commit payload
  // This is the only architectural event consumed by trace, DiffTest, and debug.
  // One commit_t describes one retired instruction; lane valid remains separate.
  typedef struct packed {
    logic [XLEN-1:0] pc;
    logic [31:0]     instruction;
    logic [XLEN-1:0] next_pc;

    logic            gpr_write;
    arch_reg_idx_t   gpr_addr;
    logic [XLEN-1:0] gpr_wdata;

    logic            csr_write;
    logic [11:0]     csr_addr;
    logic [XLEN-1:0] csr_wdata;

    logic                  memory_access;
    mem_cmd_e              memory_cmd;
    mem_size_e             memory_size;
    logic [XLEN-1:0]       memory_addr;
    logic [XLEN-1:0]       memory_rdata;
    logic [XLEN-1:0]       memory_wdata;
    logic [BYTE_LANES-1:0] memory_wmask;

    logic            trap_taken;
    logic            trap_is_interrupt;
    logic [XLEN-2:0] trap_cause_code;
    logic [XLEN-1:0] trap_tval;
    priv_mode_e      privilege;
    system_op_e      system_op;
  } commit_t;

  // P0 single-cycle execution payloads
  // Channel valid/ready is intentionally separate from every payload. P0 keeps
  // one combinational instruction path; P4 may register the same boundaries.
  typedef struct packed {
    decoded_uop_t    uop;
    logic [XLEN-1:0] rs1_value;
    logic [XLEN-1:0] rs2_value;
    logic [XLEN-1:0] csr_rdata;
    logic            csr_illegal;
  } execute_packet_t;

  typedef struct packed {
    decoded_uop_t    uop;
    logic [XLEN-1:0] result;
    logic [XLEN-1:0] next_pc;
    logic [XLEN-1:0] csr_wdata;
    logic            redirect_valid;
    redirect_req_t   redirect_req;
  } execute_result_t;

  // EXU-to-LSU request for the current in-order core. This is a request, not a
  // memory result: the LSU has not issued a data-memory transaction yet.
  // P6 replaces decoded_uop_t with ROB/LSQ identity carried by lsu_execute_req_t.
  typedef struct packed {
    decoded_uop_t    uop;
    logic [XLEN-1:0] next_pc;
    logic [XLEN-1:0] effective_addr;
    logic [XLEN-1:0] store_data;
  } lsu_req_t;

  typedef struct packed {
    decoded_uop_t          uop;
    logic [XLEN-1:0]       result;
    logic [XLEN-1:0]       next_pc;
    logic [XLEN-1:0]       csr_wdata;
    logic [XLEN-1:0]       memory_addr;
    logic [XLEN-1:0]       memory_rdata;
    logic [XLEN-1:0]       memory_wdata;
    logic [BYTE_LANES-1:0] memory_wmask;
  } writeback_result_t;

endpackage
