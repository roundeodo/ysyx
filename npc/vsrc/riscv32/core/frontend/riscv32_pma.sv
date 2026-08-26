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

  // 地址常量统一由riscv32_addr_map_pkg维护。当前SoC物理地址为32位，先按高4位
  // 选择互斥的大区域，再在该区域内检查实际窗口边界。这样不会改变地址语义，
  // 但可让综合器共享高位译码，避免为所有窗口并行生成完整的32位范围比较器。
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

  typedef enum logic [2:0] {
    PMA_REGION_UNMAPPED,
    PMA_REGION_MMIO,
    PMA_REGION_UNCACHED_RW_MEMORY,
    PMA_REGION_UNCACHED_RO_MEMORY,
    PMA_REGION_CACHEABLE_RW_MEMORY,
    PMA_REGION_CACHEABLE_RO_MEMORY
  } pma_region_class_e;

  pma_region_class_e lookup_region_class;

  // 每个case分支只处理一个互斥的256 MiB高位区域。小型MMIO窗口仍逐一检查，
  // 因为0x1000_0000附近存在未分配空洞，不能把整段地址误判为合法设备。
  always_comb begin
    lookup_region_class = PMA_REGION_UNMAPPED;

    unique case (lookup_addr_i[31:28])
      4'h0: begin
        if (phys_addr_in_range(lookup_addr_i, CLINT_BASE_ADDR, CLINT_LAST_ADDR)) begin
          lookup_region_class = PMA_REGION_MMIO;
        end else if (phys_addr_in_range(lookup_addr_i, SRAM_BASE_ADDR, SRAM_LAST_ADDR)) begin
          lookup_region_class = PMA_REGION_UNCACHED_RW_MEMORY;
        end
      end

      4'h1: begin
        if (phys_addr_in_range(lookup_addr_i, UART_BASE_ADDR, UART_LAST_ADDR) ||
            phys_addr_in_range(lookup_addr_i, SPI_REG_BASE_ADDR, SPI_REG_LAST_ADDR) ||
            phys_addr_in_range(lookup_addr_i, GPIO_BASE_ADDR, GPIO_LAST_ADDR) ||
            phys_addr_in_range(lookup_addr_i, PS2_BASE_ADDR, PS2_LAST_ADDR)) begin
          lookup_region_class = PMA_REGION_MMIO;
        end
      end

      4'h2: begin
        if (phys_addr_in_range(lookup_addr_i, MROM_BASE_ADDR, MROM_LAST_ADDR)) begin
          lookup_region_class = PMA_REGION_UNCACHED_RO_MEMORY;
        end else if (phys_addr_in_range(lookup_addr_i, VGA_BASE_ADDR, VGA_LAST_ADDR)) begin
          lookup_region_class = PMA_REGION_MMIO;
        end
      end

      4'h3: lookup_region_class = PMA_REGION_CACHEABLE_RO_MEMORY;

      4'h4, 4'h5, 4'h6, 4'h7: begin
        if (CHIPLINK_PRESENT) lookup_region_class = PMA_REGION_MMIO;
      end

      4'h8: begin
        if (phys_addr_in_range(lookup_addr_i, PSRAM_BASE_ADDR, PSRAM_LAST_ADDR)) begin
          lookup_region_class = PMA_REGION_CACHEABLE_RW_MEMORY;
        end
      end

      4'ha: begin
        if (phys_addr_in_range(lookup_addr_i, SDRAM_BASE_ADDR, SDRAM_LAST_ADDR)) begin
          lookup_region_class = PMA_REGION_CACHEABLE_RW_MEMORY;
        end
      end

      4'hc, 4'hd, 4'he, 4'hf: begin
        if (CHIPLINK_PRESENT) lookup_region_class = PMA_REGION_CACHEABLE_RW_MEMORY;
      end

      default: ;
    endcase
  end

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
  always_comb begin
    memory_attr_o = '0;

    unique case (lookup_region_class)
      PMA_REGION_UNCACHED_RW_MEMORY: begin
        memory_attr_o.readable                   = 1'b1;
        memory_attr_o.writable                   = 1'b1;
        memory_attr_o.executable                 = 1'b1;
        memory_attr_o.cacheable                  = 1'b0;
        memory_attr_o.idempotent                 = 1'b1;
        memory_attr_o.width_conversion_supported = 1'b1;
      end

      PMA_REGION_UNCACHED_RO_MEMORY: begin
        memory_attr_o.readable                   = 1'b1;
        memory_attr_o.writable                   = 1'b0;
        memory_attr_o.executable                 = 1'b1;
        memory_attr_o.cacheable                  = 1'b0;
        memory_attr_o.idempotent                 = 1'b1;
        memory_attr_o.width_conversion_supported = 1'b1;
      end

      PMA_REGION_CACHEABLE_RO_MEMORY: begin
        // Flash映射是只读XIP窗口；擦写必须通过SPI控制器寄存器完成。
        memory_attr_o.readable                   = 1'b1;
        memory_attr_o.writable                   = 1'b0;
        memory_attr_o.executable                 = 1'b1;
        memory_attr_o.cacheable                  = 1'b1;
        memory_attr_o.idempotent                 = 1'b1;
        memory_attr_o.width_conversion_supported = 1'b1;
      end

      PMA_REGION_CACHEABLE_RW_MEMORY: begin
        memory_attr_o.readable                   = 1'b1;
        memory_attr_o.writable                   = 1'b1;
        memory_attr_o.executable                 = 1'b1;
        memory_attr_o.cacheable                  = 1'b1;
        memory_attr_o.idempotent                 = 1'b1;
        memory_attr_o.width_conversion_supported = 1'b1;
      end

      PMA_REGION_MMIO: begin
        memory_attr_o.readable = 1'b1;
        memory_attr_o.writable = 1'b1;
      end

      default: ;
    endcase
  end

endmodule
