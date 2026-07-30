// Physical Memory Attributes for instruction fetch.
// This module classifies an address; it does not issue a bus request or store state.
module riscv32_pma
  import riscv32_pkg::*;
(
    input  logic [XLEN-1:0] lookup_addr_i,
    output pma_attr_t       memory_attr_o
);

  // TODO(ICACHE-PMA-1): 在本TODO正下方集中定义当前SoC地址区间。
  // 第一版至少覆盖以下区域，边界应与ysyxSoC地址图一致：
  //   SRAM   0x0f00_0000起：executable=1, cacheable=0, idempotent=1；
  //   MMIO   0x1000_0000附近：executable=0, cacheable=0, idempotent=0；
  //   MROM   0x2000_0000起：executable=1, cacheable=0, idempotent=1；
  //   Flash  0x3000_0000起：executable=1, cacheable=1, idempotent=1；
  //   PSRAM  0x8000_0000起：executable=1, cacheable=1, idempotent=1；
  //   SDRAM  0xa000_0000起：executable=1, cacheable=1, idempotent=1。
  //
  // 建议为每个区域定义BASE和MASK或BASE和END常量，例如：
  //   localparam logic [XLEN-1:0] FLASH_BASE_ADDR = 32'h3000_0000;
  //   localparam logic [XLEN-1:0] FLASH_ADDR_MASK = 32'hf000_0000;
  //
  // 长期应把整个SoC地址图提升到一个公共address-map package。当前先放在本模块，
  // 但禁止I-cache、D-cache和总线xbar再次复制一套数值后各自修改。

  // TODO(ICACHE-PMA-2): 在本TODO正下方实现纯组合地址分类。
  // 必须先给memory_attr_o='0，默认地址因此不可执行、不可缓存、非幂等；再用
  // unique case或按优先级明确的if/else覆盖已知区域。建议结构：
  //
  //   always_comb begin
  //     memory_attr_o = '0;
  //
  //     if (address_is_sram) begin
  //       memory_attr_o.executable = 1'b1;
  //       memory_attr_o.cacheable  = 1'b0;
  //       memory_attr_o.idempotent = 1'b1;
  //     end else if (...) begin
  //       ...
  //     end
  //   end
  //
  // `cacheable`只描述允许分配cache line，不描述本次是否命中。`idempotent`说明
  // 重复读取不会产生额外设备副作用，未来投机取指只能访问idempotent区域。

  // TODO(ICACHE-PMA-3): 在本TODO正下方增加仿真断言。
  // 至少检查所有声明为cacheable的区域同时也是executable和idempotent；检查区域
  // 不重叠；可选地在lookup地址落入MMIO而上游仍发起取指时输出诊断信息。

endmodule
