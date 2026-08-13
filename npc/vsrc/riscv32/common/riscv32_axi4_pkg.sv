package riscv32_axi4_pkg;

  // TODO(P2-B-AXI-1): 让AXI4 package消费全局互连配置，删除第二套宽度定义。
  // 位置：直接替换下方四个AXI4_*宽度定义。
  //
  // 完成P2-B-CFG-1和P2-B-CFG-2后，请抄写：
  //   import riscv_config_pkg::*;
  //   export riscv_config_pkg::*;
  //   localparam int unsigned AXI4_STRB_WIDTH = AXI_DATA_BYTE_COUNT;
  // export使仅导入riscv32_axi4_pkg的互连和target模块也能看见AXI_*宽度；不要要求
  // 每个AXI消费模块重复导入config package。
  //
  // 随后执行机械但必须完整的重命名：
  // - AXI4_ADDR_WIDTH -> AXI_ADDR_WIDTH
  // - AXI4_DATA_WIDTH -> AXI_DATA_WIDTH
  // - AXI4_ID_WIDTH   -> AXI_ID_WIDTH
  //
  // 删除旧的AXI4_ADDR_WIDTH、AXI4_DATA_WIDTH和AXI4_ID_WIDTH定义，不保留别名。
  // AXI4是协议名称；宽度配置名不需要带“4”。channel类型仍保留axi4_前缀，表明
  // 它们遵守AXI4协议。地址、数据和ID必须独立配置，不能从XLEN派生。
  parameter int unsigned AXI4_ADDR_WIDTH = 32;
  parameter int unsigned AXI4_DATA_WIDTH = 32;
  parameter int unsigned AXI4_ID_WIDTH = 4;
  localparam int unsigned AXI4_STRB_WIDTH = AXI4_DATA_WIDTH / 8;

  typedef enum logic [1:0] {
    AXI4_BURST_FIXED = 2'b00,
    AXI4_BURST_INCR  = 2'b01,
    AXI4_BURST_WRAP  = 2'b10
  } axi4_burst_e;

  typedef enum logic [1:0] {
    AXI4_RESP_OKAY   = 2'b00,
    AXI4_RESP_EXOKAY = 2'b01,
    AXI4_RESP_SLVERR = 2'b10,
    AXI4_RESP_DECERR = 2'b11
  } axi4_resp_e;

  // 五个channel分别拥有独立payload。即使AW和AR当前字段相同，也使用不同类型，
  // 防止模块接口或中间变量失去channel语义。
  typedef struct packed {
    logic [AXI4_ADDR_WIDTH-1:0] addr;
    logic [AXI4_ID_WIDTH-1:0]   id;
    logic [7:0]                 len;
    logic [2:0]                 size;
    axi4_burst_e                burst;
  } axi4_write_address_t;

  typedef struct packed {
    logic [AXI4_DATA_WIDTH-1:0] data;
    logic [AXI4_STRB_WIDTH-1:0] strb;
    logic                       last;
  } axi4_write_data_t;

  typedef struct packed {
    logic [AXI4_ID_WIDTH-1:0] id;
    axi4_resp_e               resp;
  } axi4_write_response_t;

  typedef struct packed {
    logic [AXI4_ADDR_WIDTH-1:0] addr;
    logic [AXI4_ID_WIDTH-1:0]   id;
    logic [7:0]                 len;
    logic [2:0]                 size;
    axi4_burst_e                burst;
  } axi4_read_address_t;

  typedef struct packed {
    logic [AXI4_DATA_WIDTH-1:0] data;
    logic [AXI4_ID_WIDTH-1:0]   id;
    axi4_resp_e                 resp;
    logic                       last;
  } axi4_read_data_t;

  // 这里只按端口方向聚合连线，不合并channel，也不改变各channel的独立握手。
  // manager_to_target包含AW/W/AR的payload和valid，以及B/R的ready。
  typedef struct packed {
    axi4_write_address_t aw;
    logic                aw_valid;
    axi4_write_data_t    w;
    logic                w_valid;
    logic                b_ready;
    axi4_read_address_t  ar;
    logic                ar_valid;
    logic                r_ready;
  } axi4_manager_to_target_t;

  // target_to_manager包含AW/W/AR的ready，以及B/R的payload和valid。
  typedef struct packed {
    logic                 aw_ready;
    logic                 w_ready;
    axi4_write_response_t b;
    logic                 b_valid;
    logic                 ar_ready;
    axi4_read_data_t      r;
    logic                 r_valid;
  } axi4_target_to_manager_t;

endpackage : riscv32_axi4_pkg
