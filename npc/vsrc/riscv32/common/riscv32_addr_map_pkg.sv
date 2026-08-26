// 当前ysyxSoC平台共用的物理地址映射。
//
// BASE_ADDR和LAST_ADDR描述实际实现的闭区间，SIZE_BYTES记录实现容量。
// 当前窗口均为按自身容量对齐的2次幂区间，因此ADDR_MATCH_MASK可以无损地
// 用于PMA和路由器的地址匹配。未来若加入非2次幂或未按容量对齐的窗口，必须
// 使用phys_addr_in_range()，或者把该窗口拆成若干个可精确匹配的掩码区间。
package riscv32_addr_map_pkg;

  import riscv_config_pkg::*;
  typedef logic [PADDR_WIDTH-1:0] phys_addr_t;

  // 由riscv32_npc_system选择并在核边界终结的CLINT窗口。
  localparam phys_addr_t CLINT_BASE_ADDR = 32'h0200_0000;
  localparam phys_addr_t CLINT_LAST_ADDR = 32'h0200_ffff;
  localparam int unsigned CLINT_SIZE_BYTES = 32'h0001_0000;
  localparam phys_addr_t CLINT_ADDR_MATCH_MASK = 32'hffff_0000;

  // 以下实际容量来自ysyxSoC/src/SoC.scala。
  localparam phys_addr_t SRAM_BASE_ADDR = 32'h0f00_0000;
  localparam phys_addr_t SRAM_LAST_ADDR = 32'h0f00_1fff;
  localparam int unsigned SRAM_SIZE_BYTES = 32'h0000_2000;
  localparam phys_addr_t SRAM_ADDR_MATCH_MASK = 32'hffff_e000;

  localparam phys_addr_t UART_BASE_ADDR = 32'h1000_0000;
  localparam phys_addr_t UART_LAST_ADDR = 32'h1000_0fff;
  localparam int unsigned UART_SIZE_BYTES = 32'h0000_1000;
  localparam phys_addr_t UART_ADDR_MATCH_MASK = 32'hffff_f000;

  localparam phys_addr_t SPI_REG_BASE_ADDR = 32'h1000_1000;
  localparam phys_addr_t SPI_REG_LAST_ADDR = 32'h1000_1fff;
  localparam int unsigned SPI_REG_SIZE_BYTES = 32'h0000_1000;
  localparam phys_addr_t SPI_REG_ADDR_MATCH_MASK = 32'hffff_f000;

  localparam phys_addr_t GPIO_BASE_ADDR = 32'h1000_2000;
  localparam phys_addr_t GPIO_LAST_ADDR = 32'h1000_200f;
  localparam int unsigned GPIO_SIZE_BYTES = 32'h0000_0010;
  localparam phys_addr_t GPIO_ADDR_MATCH_MASK = 32'hffff_fff0;

  localparam phys_addr_t PS2_BASE_ADDR = 32'h1001_1000;
  localparam phys_addr_t PS2_LAST_ADDR = 32'h1001_1007;
  localparam int unsigned PS2_SIZE_BYTES = 32'h0000_0008;
  localparam phys_addr_t PS2_ADDR_MATCH_MASK = 32'hffff_fff8;

  localparam phys_addr_t MROM_BASE_ADDR = 32'h2000_0000;
  localparam phys_addr_t MROM_LAST_ADDR = 32'h2000_0fff;
  localparam int unsigned MROM_SIZE_BYTES = 32'h0000_1000;
  localparam phys_addr_t MROM_ADDR_MATCH_MASK = 32'hffff_f000;

  localparam phys_addr_t VGA_BASE_ADDR = 32'h2100_0000;
  localparam phys_addr_t VGA_LAST_ADDR = 32'h211f_ffff;
  localparam int unsigned VGA_SIZE_BYTES = 32'h0020_0000;
  localparam phys_addr_t VGA_ADDR_MATCH_MASK = 32'hffe0_0000;

  localparam phys_addr_t FLASH_BASE_ADDR = 32'h3000_0000;
  localparam phys_addr_t FLASH_LAST_ADDR = 32'h3fff_ffff;
  localparam int unsigned FLASH_SIZE_BYTES = 32'h1000_0000;
  localparam phys_addr_t FLASH_ADDR_MATCH_MASK = 32'hf000_0000;

  // ChipLink窗口来自ysyxSoC/src/device/ChipLinkBridge.scala，只有在对应构建
  // 启用ChipLink时才可访问。
  localparam phys_addr_t CHIPLINK_MMIO_BASE_ADDR = 32'h4000_0000;
  localparam phys_addr_t CHIPLINK_MMIO_LAST_ADDR = 32'h7fff_ffff;
  localparam int unsigned CHIPLINK_MMIO_SIZE_BYTES = 32'h4000_0000;
  localparam phys_addr_t CHIPLINK_MMIO_ADDR_MATCH_MASK = 32'hc000_0000;

  localparam phys_addr_t PSRAM_BASE_ADDR = 32'h8000_0000;
  localparam phys_addr_t PSRAM_LAST_ADDR = 32'h803f_ffff;
  localparam int unsigned PSRAM_SIZE_BYTES = 32'h0040_0000;
  localparam phys_addr_t PSRAM_ADDR_MATCH_MASK = 32'hffc0_0000;

  localparam phys_addr_t SDRAM_BASE_ADDR = 32'ha000_0000;
  localparam phys_addr_t SDRAM_LAST_ADDR = 32'ha1ff_ffff;
  localparam int unsigned SDRAM_SIZE_BYTES = 32'h0200_0000;
  localparam phys_addr_t SDRAM_ADDR_MATCH_MASK = 32'hfe00_0000;

  localparam phys_addr_t CHIPLINK_MEMORY_BASE_ADDR = 32'hc000_0000;
  localparam phys_addr_t CHIPLINK_MEMORY_LAST_ADDR = 32'hffff_ffff;
  localparam int unsigned CHIPLINK_MEMORY_SIZE_BYTES = 32'h4000_0000;
  localparam phys_addr_t CHIPLINK_MEMORY_ADDR_MATCH_MASK = 32'hc000_0000;

  function automatic logic phys_addr_in_range(input phys_addr_t lookup_addr,
                                              input phys_addr_t range_base_addr,
                                              input phys_addr_t range_last_addr);
    return (lookup_addr >= range_base_addr) && (lookup_addr <= range_last_addr);
  endfunction

  // 对按容量对齐的2次幂地址窗口进行精确匹配。两侧都施加mask，避免调用者
  // 将未对齐的base直接用于比较时产生不易察觉的错误。
  function automatic logic phys_addr_matches_region(
      input phys_addr_t lookup_addr,
      input phys_addr_t region_base_addr,
      input phys_addr_t region_match_mask
  );
    return (lookup_addr & region_match_mask) ==
           (region_base_addr & region_match_mask);
  endfunction

endpackage
