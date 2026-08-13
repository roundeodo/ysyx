// 处理器命名配置的唯一来源。
//
// 本package只描述“这次构建选择了什么硬件配置”，不放ISA编码、总线事务结构、
// cache状态或模块局部派生宽度。后续RV32和RV64配置共享模块实现时，只允许从这里
// 改变全局配置，禁止各模块再次声明自己的XLEN或AXI宽度。
package riscv_config_pkg;

  // TODO(P2-B-CFG-1): 定义当前RV32基线的独立宽度配置。
  // 位置：直接写在本TODO下方。
  //
  // 请抄写以下代码：
  localparam int unsigned XLEN = 32;
  localparam int unsigned PADDR_WIDTH = 32;
  localparam int unsigned INSTR_WIDTH = 32;
  localparam int unsigned CORE_DATA_WIDTH = 32;
  localparam int unsigned AXI_ADDR_WIDTH = 32;
  localparam int unsigned AXI_DATA_WIDTH = 32;
  localparam int unsigned AXI_ID_WIDTH = 4;
  localparam int unsigned ARCH_REG_COUNT = 32;
  //
  // 各配置的所有权：
  // - XLEN：整数寄存器、ALU结果、CSR主体和立即数扩展后的宽度。
  // - PADDR_WIDTH：core能够表达的物理地址宽度，不等于XLEN。
  // - INSTR_WIDTH：基础指令编码宽度。RV64下仍然是32，不能跟随XLEN变成64。
  // - CORE_DATA_WIDTH：LSU语义请求在core侧携带的数据宽度。
  // - AXI_ADDR_WIDTH/AXI_DATA_WIDTH：SoC互连的地址和单个beat数据宽度。
  // - AXI_ID_WIDTH：AXI事务身份宽度，与ROB、LSQ和frontend tag均无关。
  // - ARCH_REG_COUNT：架构整数寄存器数量；RV32I和RV64I均为32。

  // TODO(P2-B-CFG-2): 定义只依赖全局配置、且被多个package共同使用的派生量。
  // 位置：完成P2-B-CFG-1后，紧接着写在本TODO下方。
  //
  // 请抄写以下代码：
  localparam int unsigned XLEN_BYTE_COUNT = XLEN / 8;
  localparam int unsigned CORE_DATA_BYTE_COUNT = CORE_DATA_WIDTH / 8;
  localparam int unsigned AXI_DATA_BYTE_COUNT = AXI_DATA_WIDTH / 8;
  //
  // 不要在这里计算I-cache tag、set index或line offset。这些量由I-cache几何决定，
  // 所有者是I-cache，而不是全局配置package。
  //
  // 本阶段保持XLEN == CORE_DATA_WIDTH == AXI_DATA_WIDTH == 32只是基线配置，不表示
  // 三者语义相同。P2的目的正是让以后改变其中一个时，编译错误准确暴露缺少adapter
  // 的边界，而不是通过相同位宽掩盖耦合。

  // TODO(P2-B-CFG-3): 迁入全核共享的微架构容量和构建选择。
  // 位置：直接写在本TODO下方；这些都是“选择什么实现”的配置，不是payload类型。
  //
  // 请抄写以下代码：
  localparam int unsigned FETCH_WIDTH = 1;
  localparam int unsigned DECODE_WIDTH = 1;
  localparam int unsigned RENAME_WIDTH = 1;
  localparam int unsigned DISPATCH_WIDTH = 1;
  localparam int unsigned COMMIT_WIDTH = 1;
  localparam int unsigned INT_ISSUE_WIDTH = 1;
  localparam int unsigned MEM_ISSUE_WIDTH = 1;
  //
  localparam int unsigned PHYS_REG_COUNT = 64;
  localparam int unsigned ROB_ENTRY_COUNT = 32;
  localparam int unsigned LOAD_QUEUE_COUNT = 16;
  localparam int unsigned STORE_QUEUE_COUNT = 16;
  localparam int unsigned MEM_TXN_COUNT = 16;
  localparam int unsigned FRONTEND_TAG_COUNT = 16;
  localparam int unsigned PREDICTOR_META_WIDTH = 32;
  //
  localparam int unsigned ICACHE_CAPACITY_BYTES = 8 * 1024;
  localparam int unsigned ICACHE_WAY_COUNT = 2;
  localparam int unsigned ICACHE_LINE_BYTES = 32;
  localparam int unsigned ICACHE_FETCH_BYTES = INSTR_WIDTH / 8;
  localparam int unsigned ICACHE_MSHR_COUNT = 1;
  localparam int unsigned FETCH_EPOCH_COUNT = 16;
  //
  // 命名规则：数量使用*_COUNT，位宽使用*_WIDTH，容量明确写出单位*_BYTES。
  // 不再使用*_NUM、*_ENTRIES和*_W表达同一类概念。这里的单发射和单MSHR是P2基线，
  // 不是长期性能目标；将来扩大配置时，模块必须通过同一配置入口暴露不支持的组合。
  //
  // 不要把ARCH_REG索引宽度、ROB索引宽度、I-cache set数量或tag宽度搬到这里。
  // 它们依赖具体类型或模块几何，仍由riscv32_pkg在配置值之上派生。

endpackage : riscv_config_pkg
