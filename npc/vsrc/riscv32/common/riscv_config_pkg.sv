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
  //   localparam int unsigned XLEN            = 32;
  //   localparam int unsigned PADDR_WIDTH     = 32;
  //   localparam int unsigned INSTR_WIDTH     = 32;
  //   localparam int unsigned CORE_DATA_WIDTH = 32;
  //   localparam int unsigned AXI_ADDR_WIDTH  = 32;
  //   localparam int unsigned AXI_DATA_WIDTH  = 32;
  //   localparam int unsigned AXI_ID_WIDTH    = 4;
  //   localparam int unsigned ARCH_REG_COUNT  = 32;
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
  //   localparam int unsigned XLEN_BYTE_COUNT      = XLEN / 8;
  //   localparam int unsigned CORE_DATA_BYTE_COUNT = CORE_DATA_WIDTH / 8;
  //   localparam int unsigned AXI_DATA_BYTE_COUNT  = AXI_DATA_WIDTH / 8;
  //
  // 不要在这里计算I-cache tag、set index或line offset。这些量由I-cache几何决定，
  // 所有者是I-cache，而不是全局配置package。
  //
  // 本阶段保持XLEN == CORE_DATA_WIDTH == AXI_DATA_WIDTH == 32只是基线配置，不表示
  // 三者语义相同。P2的目的正是让以后改变其中一个时，编译错误准确暴露缺少adapter
  // 的边界，而不是通过相同位宽掩盖耦合。

endpackage : riscv_config_pkg
