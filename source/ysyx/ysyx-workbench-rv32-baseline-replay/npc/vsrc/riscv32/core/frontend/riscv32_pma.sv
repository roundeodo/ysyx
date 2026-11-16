// 取指侧物理内存属性分类器。
//
// 本模块只根据物理地址产生执行、缓存、幂等和宽度转换属性，不保存状态，
// 也不发起总线请求。将地址策略独立出来，可以避免IFU、I-cache和总线适配器分别
// 复制地址判断。未来加入页表、权限检查或更完整的PMP/PMA时，lookup和refill接口
// 不需要因此改成AXI等外部协议。
module riscv32_pma
  import riscv32_addr_map_pkg::*;
  import riscv32_pkg::*;
#(
    parameter bit CHIPLINK_PRESENT = 1'b0
) (
    // PMA只判断SoC物理地址；物理地址宽度与ISA的XLEN可以独立演进。
    input  phys_addr_t lookup_addr_i,
    output pma_attr_t  memory_attr_o
);

  // 地址常量统一由riscv32_addr_map_pkg维护。PMA使用BASE_ADDR/LAST_ADDR判断
  // 实际实现的区间；ADDR_MATCH_MASK只提供给总线路由器，不能在本模块复制常量。
  // 当前有效区间为：
  //   CLINT          0x0200_0000 - 0x0200_ffff，设备空间；
  //   SRAM           0x0f00_0000 - 0x0f00_1fff，8 KiB；
  //   UART           0x1000_0000 - 0x1000_0fff，设备空间；
  //   SPI registers  0x1000_1000 - 0x1000_1fff，设备空间；
  //   GPIO           0x1000_2000 - 0x1000_200f，设备空间；
  //   PS/2           0x1001_1000 - 0x1001_1007，设备空间；
  //   MROM           0x2000_0000 - 0x2000_0fff，4 KiB；
  //   VGA            0x2100_0000 - 0x211f_ffff，设备空间；
  //   Flash XIP      0x3000_0000 - 0x3fff_ffff，256 MiB；
  //   ChipLink MMIO  0x4000_0000 - 0x7fff_ffff，可选设备空间；
  //   PSRAM          0x8000_0000 - 0x803f_ffff，4 MiB；
  //   SDRAM          0xa000_0000 - 0xa1ff_ffff，32 MiB；
  //   ChipLink MEM   0xc000_0000 - 0xffff_ffff，可选内存空间。

  // 1. 地址译码：每个信号只表示lookup地址是否落入对应的已实现物理地址区间。
  logic lookup_addr_in_clint;
  logic lookup_addr_in_sram;
  logic lookup_addr_in_uart;
  logic lookup_addr_in_spi_registers;
  logic lookup_addr_in_gpio;
  logic lookup_addr_in_ps2;
  logic lookup_addr_in_mrom;
  logic lookup_addr_in_vga;
  logic lookup_addr_in_flash;
  logic lookup_addr_in_chiplink_mmio;
  logic lookup_addr_in_psram;
  logic lookup_addr_in_sdram;
  logic lookup_addr_in_chiplink_memory;
  logic lookup_addr_in_any_mmio;
  logic lookup_addr_in_any_cacheable_memory;

  // 这里不使用模糊的统一MMIO大区间，因为0x1000_0000附近存在未分配空洞；
  // 未分配地址必须保留默认非法属性，不能因为高位相同就误判成合法设备。
  always_comb begin
    lookup_addr_in_clint = phys_addr_in_range(lookup_addr_i, CLINT_BASE_ADDR, CLINT_LAST_ADDR);
    lookup_addr_in_sram  = phys_addr_in_range(lookup_addr_i, SRAM_BASE_ADDR, SRAM_LAST_ADDR);
    lookup_addr_in_uart  = phys_addr_in_range(lookup_addr_i, UART_BASE_ADDR, UART_LAST_ADDR);

    lookup_addr_in_spi_registers =
        phys_addr_in_range(lookup_addr_i, SPI_REG_BASE_ADDR, SPI_REG_LAST_ADDR);

    lookup_addr_in_gpio  = phys_addr_in_range(lookup_addr_i, GPIO_BASE_ADDR, GPIO_LAST_ADDR);
    lookup_addr_in_ps2   = phys_addr_in_range(lookup_addr_i, PS2_BASE_ADDR, PS2_LAST_ADDR);
    lookup_addr_in_mrom  = phys_addr_in_range(lookup_addr_i, MROM_BASE_ADDR, MROM_LAST_ADDR);
    lookup_addr_in_vga   = phys_addr_in_range(lookup_addr_i, VGA_BASE_ADDR, VGA_LAST_ADDR);
    lookup_addr_in_flash = phys_addr_in_range(lookup_addr_i, FLASH_BASE_ADDR, FLASH_LAST_ADDR);

    lookup_addr_in_chiplink_mmio = CHIPLINK_PRESENT &&
        phys_addr_in_range(lookup_addr_i, CHIPLINK_MMIO_BASE_ADDR, CHIPLINK_MMIO_LAST_ADDR);

    lookup_addr_in_psram = phys_addr_in_range(lookup_addr_i, PSRAM_BASE_ADDR, PSRAM_LAST_ADDR);
    lookup_addr_in_sdram = phys_addr_in_range(lookup_addr_i, SDRAM_BASE_ADDR, SDRAM_LAST_ADDR);

    lookup_addr_in_chiplink_memory = CHIPLINK_PRESENT &&
        phys_addr_in_range(lookup_addr_i, CHIPLINK_MEMORY_BASE_ADDR, CHIPLINK_MEMORY_LAST_ADDR);

    lookup_addr_in_any_mmio = lookup_addr_in_clint || lookup_addr_in_uart ||
                              lookup_addr_in_spi_registers || lookup_addr_in_gpio ||
                              lookup_addr_in_ps2 || lookup_addr_in_vga ||
                              lookup_addr_in_chiplink_mmio;

    lookup_addr_in_any_cacheable_memory = lookup_addr_in_flash || lookup_addr_in_psram ||
                                          lookup_addr_in_sdram ||
                                          lookup_addr_in_chiplink_memory;
  end

  // 2. 属性输出：组合编码，无寄存器。
  // pma_attr_t字段的含义：
  //   readable/writable：数据侧访问权限；未映射地址两者均为0；
  //   executable：允许IFU从该区域取指；为0时I-cache返回取指访问异常；
  //   cacheable ：允许把该区域读出的整条cache line留在I-cache；
  //   idempotent：重复读取不会改变设备状态，允许未来进行投机取指或重复refill。
  //   width_conversion_supported：允许总线边界把一次宽访问拆成多个窄事务。
  //
  // SRAM不缓存是当前系统策略：它本身只有约1周期访问延迟，缓存收益很小。
  // MROM同样保持不缓存。Flash、PSRAM和SDRAM延迟高且读操作无设备副作用，
  // 因而允许取指、允许缓存且幂等。MMIO必须全部不可执行、不可缓存、非幂等。
  // 显式按区域分类可以清楚表达只读和可写内存的差异。曾尝试将属性改写为
  // 多个区域命中信号的并行布尔方程，但标准单元映射后扩大了IFU高扇出逻辑锥，
  // 在周期数不变的前提下同时恶化了面积、Fmax和TNS，因此保留本优先级形式。
  always_comb begin
    memory_attr_o = '0;

    if (lookup_addr_in_sram) begin
      memory_attr_o.readable                   = 1'b1;
      memory_attr_o.writable                   = 1'b1;
      memory_attr_o.executable                 = 1'b1;
      memory_attr_o.idempotent                 = 1'b1;
      memory_attr_o.width_conversion_supported = 1'b1;
    end else if (lookup_addr_in_mrom) begin
      memory_attr_o.readable                   = 1'b1;
      memory_attr_o.executable                 = 1'b1;
      memory_attr_o.idempotent                 = 1'b1;
      memory_attr_o.width_conversion_supported = 1'b1;
    end else if (lookup_addr_in_flash) begin
      memory_attr_o.readable                   = 1'b1;
      memory_attr_o.executable                 = 1'b1;
      memory_attr_o.cacheable                  = 1'b1;
      memory_attr_o.idempotent                 = 1'b1;
      memory_attr_o.width_conversion_supported = 1'b1;
    end else if (lookup_addr_in_any_cacheable_memory) begin
      memory_attr_o.readable                   = 1'b1;
      memory_attr_o.writable                   = 1'b1;
      memory_attr_o.executable                 = 1'b1;
      memory_attr_o.cacheable                  = 1'b1;
      memory_attr_o.idempotent                 = 1'b1;
      memory_attr_o.width_conversion_supported = 1'b1;
    end else if (lookup_addr_in_any_mmio) begin
      memory_attr_o.readable = 1'b1;
      memory_attr_o.writable = 1'b1;
    end
  end

endmodule
