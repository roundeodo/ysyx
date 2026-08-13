// 全核共享的架构常量、语义枚举和模块间载荷类型。
// 本package是模块间契约的唯一来源；valid/ready握手与模块局部状态不进入payload。
package riscv32_pkg;

  // TODO(P2-B-PKG-1): 让本package消费唯一配置，并删除重复配置源。
  // 位置：在现有addr_map import之前加入config import；随后删除下方由config接管的
  // 架构配置、流水宽度和后端容量定义。
  //
  // 完成P2-B-CFG-1后，请执行以下三步：
  // 1. 在本TODO下方加入：
  //      import riscv_config_pkg::*;
  //      export riscv_config_pkg::*;
  //    import让本package内部可使用配置名；export让只导入riscv32_pkg的模块也能继续
  //    看见这些全局配置。否则每个core模块都必须重复导入config package。
  // 2. 删除下方从XLEN到PREDICTOR_META_W的全部parameter定义。它们已经分别由
  //    P2-B-CFG-1和P2-B-CFG-3接管。
  // 3. 在本文件执行以下完整重命名，不要保留旧名字作为兼容别名：
  //      ARCH_REG_NUM     -> ARCH_REG_COUNT
  //      PHYS_REG_NUM     -> PHYS_REG_COUNT
  //      ROB_ENTRIES      -> ROB_ENTRY_COUNT
  //      LQ_ENTRIES       -> LOAD_QUEUE_COUNT
  //      SQ_ENTRIES       -> STORE_QUEUE_COUNT
  //      MEM_TXN_ENTRIES  -> MEM_TXN_COUNT
  //      PREDICTOR_META_W -> PREDICTOR_META_WIDTH
  // 4. 将BYTE_LANES删除；需要core字节通道数的位置统一使用CORE_DATA_BYTE_COUNT。
  //
  // 删除旧定义非常重要：如果两个package都能决定XLEN，未来会出现“改了配置却只有
  // 部分模块变宽”的静默错误。P2要求每个全局配置只有一个所有者。
  import riscv32_addr_map_pkg::*;

  // 架构与微架构配置
  parameter int unsigned XLEN = 32;
  parameter int unsigned ARCH_REG_NUM = 32;

  // 当前仍为单发射；未来增加lane数量时保持payload语义和模块职责不变。
  /* verilator lint_off UNUSEDPARAM */
  parameter int unsigned FETCH_WIDTH = 1;
  parameter int unsigned DECODE_WIDTH = 1;
  parameter int unsigned RENAME_WIDTH = 1;
  parameter int unsigned DISPATCH_WIDTH = 1;
  parameter int unsigned COMMIT_WIDTH = 1;
  parameter int unsigned INT_ISSUE_WIDTH = 1;
  parameter int unsigned MEM_ISSUE_WIDTH = 1;
  /* verilator lint_on UNUSEDPARAM */

  // 后端容量集中定义，使rename、ROB、issue和恢复逻辑使用同一套索引宽度。
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

  // TODO(P2-B-PKG-2): 在payload之前建立语义基础类型，并停止用logic[XLEN-1:0]
  // 同时表示指令、标量数据、PC和物理地址。
  // 位置：直接写在本TODO下方，位于索引类型和所有payload定义之前。
  //
  // 完成P2-B-PKG-1后，请抄写：
  //   typedef logic [INSTR_WIDTH-1:0]     instruction_t;
  //   typedef logic [XLEN-1:0]            xlen_data_t;
  //   typedef logic [XLEN-1:0]            program_counter_t;
  //   typedef logic [CORE_DATA_WIDTH-1:0] core_data_t;
  //   typedef logic [CORE_DATA_BYTE_COUNT-1:0] core_byte_strobe_t;
  //
  // 类型含义：
  // - instruction_t永远表示一条基础指令的编码，不随RV64加宽。
  // - xlen_data_t表示GPR、ALU、CSR和符号扩展后的立即数。
  // - program_counter_t当前与XLEN同宽，但独立命名让PC语义在接口中可见。
  // - core_data_t/core_byte_strobe_t只属于core侧数据存储接口。
  //
  // 这里不要重新定义phys_addr_t。物理地址类型属于addr_map package；本package已经
  // import它。也不要在P2-B立刻替换下面全部payload，那属于P2-C/P2-D。P2-B先建立
  // 类型和唯一配置源，并保持电路行为不变。

  /* verilator lint_off UNUSEDPARAM */
  parameter logic [XLEN-1:0] RESET_VECTOR = FLASH_BASE_ADDR;

  // ISA编码常量。只有IDU/decode lane负责把指令编码转换为语义操作。
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

  // 统一索引类型
  typedef logic [ARCH_REG_IDX_W-1:0] arch_reg_idx_t;
  typedef logic [PHYS_REG_IDX_W-1:0] phys_reg_idx_t;
  typedef logic [ROB_IDX_W-1:0] rob_idx_t;
  typedef logic [LQ_IDX_W-1:0] lq_idx_t;
  typedef logic [SQ_IDX_W-1:0] sq_idx_t;
  typedef logic [MEM_TXN_IDX_W-1:0] mem_txn_id_t;
  typedef logic [FRONTEND_TAG_W-1:0] frontend_tag_t;

  // 语义操作枚举。零值表示不产生副作用，使组合逻辑可以统一使用payload='0作为默认值。
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
    REDIRECT_DEBUG             = 3'd5,
    REDIRECT_FENCE_I           = 3'd6
  } redirect_reason_e;

  typedef enum logic [1:0] {
    PRIV_MODE_U = 2'b00,
    PRIV_MODE_S = 2'b01,
    PRIV_MODE_M = 2'b11
  } priv_mode_e;

  // 译码控制分组。decoded_uop_t用于常规lane连线；进入时序敏感的后端路径前，使用
  // 专用issue payload去掉与目标执行单元无关的字段。
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

  // TODO(P2-B-PKG-3): 删除已经迁入配置package的I-cache构建参数。
  // 位置：本TODO下方就是需要删除的六个parameter；保留下方所有localparam派生量。
  //
  // 完成P2-B-CFG-3和P2-B-PKG-1后：
  // 1. 删除ICACHE_CAPACITY_BYTES至FETCH_EPOCH_COUNT这六个旧parameter定义；
  // 2. 不改下面set/word/index/tag等派生公式；这些公式属于共享I-cache类型的所有者；
  // 3. 将ICACHE_TAG_W公式中的XLEN改为PADDR_WIDTH，因为cache tag来自物理取指地址，
  //    RV64配置不能让32位SoC物理地址的tag无故变宽；
  // 4. 本步骤不替换lookup payload里的地址和数据类型，那是P2-C/P2-D的工作。
  //
  // 删除旧定义后，数值仍由riscv_config_pkg提供，因此本步骤不改变cache容量或行为。
  // I-cache几何参数只在这里定义一次，前端各子模块统一使用下面的派生宽度，禁止各自
  // 硬编码地址切片。当前基线为8KiB、2路组相联、32B cache line和4B取指宽度，地址
  // 划分为tag[31:12]、set[11:5]、line offset[4:0]。
  parameter int unsigned ICACHE_CAPACITY_BYTES = 8 * 1024;
  parameter int unsigned ICACHE_WAY_COUNT = 2;
  parameter int unsigned ICACHE_LINE_BYTES = 32;
  parameter int unsigned ICACHE_FETCH_BYTES = 4;
  parameter int unsigned ICACHE_MSHR_COUNT = 1;
  parameter int unsigned FETCH_EPOCH_COUNT = 16;

  localparam int unsigned ICACHE_SET_COUNT =
      ICACHE_CAPACITY_BYTES / (ICACHE_WAY_COUNT * ICACHE_LINE_BYTES);
  localparam int unsigned ICACHE_WORDS_PER_LINE = ICACHE_LINE_BYTES / ICACHE_FETCH_BYTES;
  localparam int unsigned ICACHE_SET_INDEX_W = (ICACHE_SET_COUNT > 1) ? $clog2(
      ICACHE_SET_COUNT
  ) : 1;
  localparam int unsigned ICACHE_WORD_INDEX_W = (ICACHE_WORDS_PER_LINE > 1) ? $clog2(
      ICACHE_WORDS_PER_LINE
  ) : 1;
  localparam int unsigned ICACHE_WAY_INDEX_W = (ICACHE_WAY_COUNT > 1) ? $clog2(
      ICACHE_WAY_COUNT
  ) : 1;
  localparam int unsigned ICACHE_LINE_OFFSET_W = $clog2(ICACHE_LINE_BYTES);
  localparam int unsigned ICACHE_TAG_W = XLEN - ICACHE_LINE_OFFSET_W - ICACHE_SET_INDEX_W;
  localparam int unsigned FETCH_EPOCH_W = (FETCH_EPOCH_COUNT > 1) ? $clog2(FETCH_EPOCH_COUNT) : 1;


  // fetch_epoch不是总线transaction ID。redirect发生时IFU递增epoch；较老epoch的
  // 返回结果仍可完成memory握手，但不能进入fetch buffer。epoch回绕安全的前提是
  // 同时在途的前端事务数量严格小于FETCH_EPOCH_COUNT。
  typedef logic [ICACHE_SET_INDEX_W-1:0] icache_set_index_t;
  typedef logic [ICACHE_WORD_INDEX_W-1:0] icache_word_index_t;
  typedef logic [ICACHE_WAY_INDEX_W-1:0] icache_way_index_t;
  typedef logic [ICACHE_TAG_W-1:0] icache_tag_t;
  typedef logic [FETCH_EPOCH_W-1:0] fetch_epoch_t;

  // valid/ready必须继续作为模块端口上的独立logic，不能放进这些结构体。
  // 字段不使用时必须赋0，不允许未使用的payload传播X。
  // frontend_tag是IFU分配的前端请求身份，response必须原样返回；它和fetch_epoch
  // 分别解决“这是哪个请求”和“这个请求是否仍属于当前控制流”两个问题。
  // lookup响应保留fetch_addr，因为IFU需要把返回数据与PC重新关联；I-cache只返回
  // 原始取指数据，不在cache中构造fetch_entry_t，也不负责分支预测或异常提交。
  typedef struct packed {
    logic executable;
    logic cacheable;
    logic idempotent;
  } pma_attr_t;

  typedef struct packed {
    logic [XLEN-1:0] fetch_addr;
    frontend_tag_t   frontend_tag;
    fetch_epoch_t    fetch_epoch;
  } icache_lookup_req_t;

  typedef struct packed {
    logic [XLEN-1:0]                 fetch_addr;
    logic [ICACHE_FETCH_BYTES*8-1:0] fetch_data;
    frontend_tag_t                   frontend_tag;
    fetch_epoch_t                    fetch_epoch;
    logic                            access_fault;
  } icache_lookup_resp_t;

  // transaction_index是miss unit和refill adapter之间的本地身份，
  // 不等同于IFU分配的frontend_tag，也不等同于AXI4 ID。
  // line_base_addr低ICACHE_LINE_OFFSET_W位必须为0。cache miss令
  // requested_word_count=ICACHE_WORDS_PER_LINE，此时adapter从line_base_addr开始发出
  // AXI4 INCR burst；uncached fetch令requested_word_count=1，此时adapter从
  // line_base_addr + critical_word_index * ICACHE_FETCH_BYTES读取目标word。
  // response.word_index始终表示word在原cache line中的位置。cacheable refill按地址升序
  // 返回，critical_word_index只判断哪个自然到达的beat可以触发early restart，不改变
  // burst顺序。last_word是本地refill通道的事务结束标志，由AXI4 RLAST导出。
  typedef struct packed {
    icache_lookup_req_t lookup_req;
    pma_attr_t          memory_attr;
    icache_set_index_t  set_index;
    icache_word_index_t critical_word_index;
    icache_way_index_t  replacement_way_index;
    icache_tag_t        refill_tag;
  } icache_miss_req_t;

  localparam int unsigned ICACHE_REFILL_TRANSACTION_COUNT = ICACHE_MSHR_COUNT;
  localparam int unsigned ICACHE_REFILL_TRANSACTION_INDEX_W =
      (ICACHE_REFILL_TRANSACTION_COUNT > 1) ? $clog2(
      ICACHE_REFILL_TRANSACTION_COUNT
  ) : 1;
  localparam int unsigned ICACHE_REFILL_WORD_COUNT_W = $clog2(ICACHE_WORDS_PER_LINE + 1);
  typedef logic [ICACHE_REFILL_TRANSACTION_INDEX_W-1:0] icache_refill_transaction_index_t;
  typedef logic [ICACHE_REFILL_WORD_COUNT_W-1:0] icache_refill_word_count_t;

  typedef struct packed {
    logic [XLEN-1:0]                  line_base_addr;
    icache_word_index_t               critical_word_index;
    icache_refill_word_count_t        requested_word_count;
    icache_refill_transaction_index_t transaction_index;
  } icache_refill_req_t;

  typedef struct packed {
    logic [ICACHE_FETCH_BYTES*8-1:0]  word_data;
    icache_word_index_t               word_index;
    logic                             last_word;
    logic                             access_fault;
    icache_refill_transaction_index_t transaction_index;
  } icache_refill_resp_t;
  // 这些字段描述“本周期发生了什么”，因此使用occurred后缀；它们不得反向控制cache：
  typedef struct packed {
    logic lookup_occurred;
    logic hit_occurred;
    logic miss_occurred;
    logic uncached_access_occurred;
    logic refill_word_occurred;
    logic refill_line_completed_occurred;
    logic stale_response_discarded_occurred;
  } icache_event_t;

  // LSU与数据存储层之间传递语义请求，不在LSU内暴露AXI4通道。
  // transaction_id在当前阻塞核中可固定为0；未来引入load/store queue和
  // 多个在途miss后，它用于将返回数据与原始存储事务重新关联。
  typedef struct packed {
    logic [XLEN-1:0]       addr;
    mem_cmd_e              cmd;
    mem_size_e             size;
    logic [XLEN-1:0]       write_data;
    logic [BYTE_LANES-1:0] byte_strobe;
    mem_txn_id_t           transaction_id;
  } data_memory_req_t;

  typedef struct packed {
    logic [XLEN-1:0] read_data;
    logic            access_fault;
    mem_txn_id_t     transaction_id;
  } data_memory_resp_t;

  // 后续扩展事件时先写清楚计数关系。例如lookup = hit + miss + uncached access；
  // access fault是否单独计数必须在设计记录中冻结，不能让两个监视器使用不同定义。

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

  // AXI4通道payload与方向聚合类型只能定义在riscv32_axi4_pkg中。
  // 核内功能单元使用本地语义接口，只有cache refill、uncached manager、
  // 互联和外设边界可以看到完整AXI4协议字段。
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
