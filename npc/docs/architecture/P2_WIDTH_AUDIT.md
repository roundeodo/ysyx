# P2宽度依赖审计

状态：P2已完成

基线提交：`ce27fb8eed29c0b039dc11ddc66407c096486a16`

最后更新：2026-08-14

## 1. 审计规则

每一处宽度只能属于以下四类之一：

| 分类 | 定义 | 处理方式 |
| --- | --- | --- |
| ISA固定 | 由RISC-V编码或架构规范固定 | 保留固定宽度，并使用能表达语义的类型或常量 |
| 命名配置 | 随RV32/RV64或SoC配置变化 | 迁入配置package |
| 局部派生 | 由line、lane、set、ID等模块参数计算 | 在拥有该结构的模块中用`$clog2`或`$bits`派生 |
| 错误硬编码 | 实际依赖配置却直接写成32 | 删除硬编码，改用配置项或语义类型 |

审计目标不是消除所有数字`32`。RISC-V基础指令编码保持32位，SoC物理地址和AXI数据宽度
也可以继续为32位，但它们不能再通过`XLEN`间接表达。

## 2. 第一轮发现

| 所有者 | 当前依赖 | 分类 | 迁移动作 |
| --- | --- | --- | --- |
| `riscv32_pkg.sv` | `XLEN = 32` | 命名配置 | 已迁入`riscv_config_pkg.sv` |
| `riscv32_pkg.sv` | `instruction[31:0]` | ISA固定 | 定义独立`instruction_t`，不得改成`XLEN` |
| `riscv32_pkg.sv` | core数据字节数 | 命名配置/局部派生 | 已改为由`CORE_DATA_WIDTH`派生的`CORE_DATA_BYTE_COUNT` |
| `riscv32_pkg.sv` | `ICACHE_TAG_W = XLEN - ...` | 错误耦合 | 改由取指物理地址宽度派生 |
| `riscv32_pkg.sv` | fetch、redirect和memory地址使用`XLEN` | 错误耦合 | 区分虚拟PC、物理地址和标量数据类型 |
| `riscv32_addr_map_pkg.sv` | `soc_phys_addr_t[31:0]` | 命名配置 | 使用`PADDR_WIDTH`；地址常量保持SoC配置值 |
| `riscv32_axi4_pkg.sv` | 地址、data、strb固定32位 | 命名配置 | 分离`AXI_ADDR_WIDTH`、`AXI_DATA_WIDTH`和派生strobe宽度 |
| `riscv32_idu.sv` | instruction和立即数均为32位 | 混合 | instruction是ISA固定；立即数结果扩展到`XLEN` |
| `riscv32_exu.sv` | `32'd4`、`~32'h1` | 错误硬编码 | 分别使用指令字节数和`XLEN`宽度掩码 |
| `riscv32_csr_file.sv` | CSR存储体固定32位 | 命名配置 | machine CSR主体改用`XLEN`，固定字段单独保留 |
| `riscv32_pmu.sv` | RV32方式访问64位计数器高低半部 | ISA/配置混合 | RV32保留高半CSR；RV64配置一次返回64位并复核写语义 |
| `riscv32_icache*.sv` | 地址和word数据均使用`XLEN` | 错误耦合 | 地址使用取指地址类型，array word使用fetch word宽度 |
| `riscv32_lsu.sv` | load结果和AXI beat隐含同宽 | 错误耦合 | core数据宽度与AXI数据宽度分别建模，转换只在adapter中发生 |
| `riscv32_npc_axi.sv` | ysyxSoC顶层端口固定32位 | 外部契约 | 保持接口要求，但内部连接使用AXI配置类型并加宽度断言 |
| 仿真/DPI边界 | 地址、数据和格式化输出默认32位 | 配置/宿主接口 | 明确转换位置，禁止依靠C++隐式截断 |

## 3. 迁移顺序

1. P2-B新增配置package，只迁移宽度和容量，不修改行为。
2. 在ISA package中引入`instruction_t`、`xlen_data_t`、`phys_addr_t`等语义类型。
3. 先迁移公共payload，再迁移寄存器堆、IDU/EXU、CSR/trap、LSU和前端。
4. 最后迁移AXI adapter和仿真边界；每个检查点运行NPC/SoC lint和dummy。

P2-C已经完成第3项中的core内部迁移：寄存器堆、IDU/EXU、CSR/trap、PMU、LSU和前端
均改用语义类型。P2-D完成第4项：core宽度变化由明确的adapter终止，不能隐式传播到AXI
或仿真边界。

## 4. 最终审计结果

| 固定宽度或写法 | 所有者 | 结论 |
| --- | --- | --- |
| ysyxSoC顶层AXI端口`[31:0]` | 外部SoC接口规范 | 保留在wrapper边界，内部使用AXI语义类型 |
| RISC-V基础指令32位 | ISA | 保留为`instruction_t`，不随`XLEN`变化 |
| CSR地址12位及opcode/funct字段 | ISA | 保留固定宽度 |
| SoC设备地址常量 | address-map package | 保留具体映射值，不用于表达数据通路宽度 |
| core标量和寄存器宽度 | 命名配置 | 只由`XLEN`及语义类型表达 |
| cache tag/index/offset | cache局部参数 | 从物理地址和cache几何派生 |
| AXI lane、size和strobe | AXI配置/adapter | 从`AXI_DATA_WIDTH`派生 |
| C++/DPI数据载体 | 仿真边界 | 显式转换，不能依靠宿主语言隐式截断 |

活动RTL不再保留AXI4-Lite兼容路径。历史文档可以描述迁移过程，但filelist中的实现只使用
完整AXI4。64位core侧到32位AXI侧的拆分和合并行为已由独立单元测试固定。

## 5. 当前禁止事项

- 禁止全局把`[31:0]`替换为`[XLEN-1:0]`。
- 禁止为RV32和RV64复制两套数据通路。
- 禁止保留旧宽度别名作为兼容层。
- 禁止在宽度adapter完成单元测试前把RV64配置接入主线。
