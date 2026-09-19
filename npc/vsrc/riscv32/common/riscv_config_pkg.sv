// 处理器命名配置的唯一来源。
//
// 本package只描述“这次构建选择了什么硬件配置”，不放ISA编码、总线事务结构、
// cache状态或模块局部派生宽度。后续RV32和RV64配置共享模块实现时，只允许从这里
// 改变全局配置，禁止各模块再次声明自己的XLEN或AXI宽度。
package riscv_config_pkg;

  // 正式配置由Makefile唯一选择。无配置或重复配置只为配置检查保留零宽占位值，
  // 正常RTL构建会在Make阶段直接拒绝，不允许功能模块自行选择默认配置。
`ifdef YSYX_RV32_BASELINE
`ifdef YSYX_RV64_SEQUENTIAL
  localparam int unsigned CONFIG_SELECTION_COUNT = 2;
  localparam int unsigned XLEN = 0;
  localparam int unsigned CORE_DATA_WIDTH = 0;
  localparam int unsigned MEM_AXI_DATA_WIDTH = 0;
`else
  localparam int unsigned CONFIG_SELECTION_COUNT = 1;
  localparam int unsigned XLEN = 32;
  localparam int unsigned CORE_DATA_WIDTH = 32;
  localparam int unsigned MEM_AXI_DATA_WIDTH = 32;
`endif
`elsif YSYX_RV64_SEQUENTIAL
  localparam int unsigned CONFIG_SELECTION_COUNT = 1;
  localparam int unsigned XLEN = 64;
  localparam int unsigned CORE_DATA_WIDTH = 64;
  localparam int unsigned MEM_AXI_DATA_WIDTH = 64;
`else
  localparam int unsigned CONFIG_SELECTION_COUNT = 0;
  localparam int unsigned XLEN = 0;
  localparam int unsigned CORE_DATA_WIDTH = 0;
  localparam int unsigned MEM_AXI_DATA_WIDTH = 0;
`endif

  localparam int unsigned PADDR_WIDTH = 32;
  localparam int unsigned INSTR_WIDTH = 32;
  localparam int unsigned ARCH_REG_COUNT = 32;

  // 正式core/cache memory AXI属于处理器架构边界。RV64配置使用64位数据beat。
  localparam int unsigned MEM_AXI_ADDR_WIDTH = 32;
  localparam int unsigned MEM_AXI_ID_WIDTH = 4;

  // 当前 ysyxSoC CPU 插槽固定为 AXI32，只在 system wrapper 中转换宽度，
  // 不能把开发板限制传播到core、cache或standalone memory AXI中。
  localparam int unsigned YSYX_SOC_AXI_ADDR_WIDTH = 32;
  localparam int unsigned YSYX_SOC_AXI_DATA_WIDTH = 32;
  localparam int unsigned YSYX_SOC_AXI_ID_WIDTH = 4;
  //
  // 各配置的所有权：
  // - XLEN：整数寄存器、ALU结果、CSR主体和立即数扩展后的宽度。
  // - PADDR_WIDTH：core能够表达的物理地址宽度，不等于XLEN。
  // - INSTR_WIDTH：基础指令编码宽度。RV64下仍然是32，不能跟随XLEN变成64。
  // - CORE_DATA_WIDTH：LSU语义请求在core侧携带的数据宽度。
  // - MEM_AXI_*：core/cache到主存系统的正式AXI边界。
  // - YSYX_SOC_AXI_*：当前课程SoC插槽边界，只由system wrapper消费。
  // - ARCH_REG_COUNT：架构整数寄存器数量；RV32I和RV64I均为32。

  // 只依赖全局配置、且被多个package共同使用的派生量。
  localparam int unsigned XLEN_BYTE_COUNT = XLEN / 8;
  localparam int unsigned CORE_DATA_BYTE_COUNT = CORE_DATA_WIDTH / 8;
  localparam int unsigned MEM_AXI_DATA_BYTE_COUNT = MEM_AXI_DATA_WIDTH / 8;
  localparam int unsigned YSYX_SOC_AXI_DATA_BYTE_COUNT = YSYX_SOC_AXI_DATA_WIDTH / 8;
  //
  // 不要在这里计算I-cache tag、set index或line offset。这些量由I-cache几何决定，
  // 所有者是I-cache，而不是全局配置package。
  //
  // RV32基线中XLEN、core数据和memory AXI恰好都是32位；RV64配置把前三者提升
  // 到64位，但物理地址、指令和ysyxSoC AXI仍保持32位。相同数值不表示语义相同。

  // 全核共享的微架构容量和构建选择。这些参数描述“选择什么实现”，不是payload类型。
  localparam int unsigned FETCH_WIDTH = 1;
  localparam int unsigned DECODE_WIDTH = 1;
  // RENAME_WIDTH / DISPATCH_WIDTH 供保留的实验类型使用，当前核不含重命名。
  localparam int unsigned RENAME_WIDTH = 1;
  localparam int unsigned DISPATCH_WIDTH = 1;
  localparam int unsigned COMMIT_WIDTH = 1;
  localparam int unsigned INT_ISSUE_WIDTH = 1;
  localparam int unsigned MEM_ISSUE_WIDTH = 1;
  // 以下容量供实验类型使用；当前核未实例化物理寄存器堆、ROB 或 LSQ。
  localparam int unsigned PHYS_REG_COUNT = 64;
  localparam int unsigned ROB_ENTRY_COUNT = 32;
  localparam int unsigned LOAD_QUEUE_COUNT = 16;
  localparam int unsigned STORE_QUEUE_COUNT = 16;
  localparam int unsigned MEM_TXN_COUNT = 16;
  // frontend tag 关联预测结果与取指请求，epoch 区分重定向前后的请求。
  // 当前各保留 4 个编码；修改队列容量或重定向流程时，需重新验证旧响应不会误匹配。
  localparam int unsigned FRONTEND_TAG_COUNT = 4;
  // 请求侧next-PC predictor的容量也属于命名配置。BTB_ENTRY_COUNT是总表项数，
  // BTB_WAY_COUNT是每个set的路数；改变二者不能改变IFU携带prediction的协议。
  localparam int unsigned BRANCH_HISTORY_ENTRY_COUNT = `YSYX_BRANCH_HISTORY_ENTRY_COUNT;
  localparam int unsigned BRANCH_TARGET_ENTRY_COUNT  = `YSYX_BRANCH_TARGET_ENTRY_COUNT;
  localparam int unsigned BRANCH_TARGET_WAY_COUNT    = `YSYX_BRANCH_TARGET_WAY_COUNT;
  localparam int unsigned RETURN_STACK_ENTRY_COUNT   = `YSYX_RETURN_STACK_ENTRY_COUNT;
  //
  // I-cache容量、路数与line大小由Makefile唯一选择；set数量、tag/offset宽度、
  // data array深度和AXI4 burst长度全部由下游派生，禁止逐模块修改。
  localparam int unsigned ICACHE_CAPACITY_BYTES = `YSYX_ICACHE_CAPACITY_BYTES;
  localparam int unsigned ICACHE_WAY_COUNT = `YSYX_ICACHE_WAY_COUNT;
  localparam int unsigned ICACHE_LINE_BYTES = `YSYX_ICACHE_LINE_BYTES;
  localparam int unsigned ICACHE_FETCH_BYTES = INSTR_WIDTH / 8;
  localparam int unsigned ICACHE_MSHR_COUNT = 1;
  // 课程面积配置在elaboration时完全移除D-cache实例；这不是运行时旁路，也不会为
  // 未实例化的array保留触发器。LSU/PMA/AXI协议保持不变，cacheable请求改走uncached路径。
  localparam bit DCACHE_ENABLED = (`YSYX_DCACHE_ENABLE != 0);
  // 当前 D-cache 为阻塞式单 miss 结构，容量、路数和行大小由构建配置决定。
  localparam int unsigned DCACHE_CAPACITY_BYTES = `YSYX_DCACHE_CAPACITY_BYTES;
  localparam int unsigned DCACHE_WAY_COUNT = `YSYX_DCACHE_WAY_COUNT;
  localparam int unsigned DCACHE_LINE_BYTES = `YSYX_DCACHE_LINE_BYTES;
  localparam int unsigned DCACHE_MSHR_COUNT = 1;
  localparam int unsigned FETCH_EPOCH_COUNT = 4;
  //
  // 命名规则：数量使用*_COUNT，位宽使用*_WIDTH，容量明确写出单位*_BYTES。
  // 当前实现为单发射、单 MSHR；不支持的参数组合须在构建或 elaboration 时报告。
  //
  // 不要把ARCH_REG索引宽度、ROB索引宽度、I-cache set数量或tag宽度搬到这里。
  // 它们依赖具体类型或模块几何，仍由riscv32_pkg在配置值之上派生。

endpackage : riscv_config_pkg
