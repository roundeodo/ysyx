# P2配置层和宽度解耦计划

状态：P2已完成，下一检查点为P3 RV64顺序功能基线范围冻结

最后更新：2026-08-14

## 1. 目标

P2不是把文件名中的`riscv32`机械替换成`riscv64`，而是先消除当前实现中架构宽度、物理
地址宽度、取指宽度、core访存宽度和SoC AXI宽度之间的隐式等同。完成后，RV32与RV64是
两套经过回归的命名配置，共享同一份模块实现。

本阶段冻结以下配置维度：

| 维度 | 含义 | 当前基线 |
| --- | --- | ---: |
| `XLEN` | 整数寄存器和标量运算宽度 | 32 |
| `PADDR_WIDTH` | 物理地址宽度 | 32 |
| `INSTR_WIDTH` | 基础指令编码宽度 | 32 |
| `CORE_DATA_WIDTH` | core侧访存数据宽度 | 32 |
| `AXI_ADDR_WIDTH` | SoC AXI地址宽度 | 32 |
| `AXI_DATA_WIDTH` | P2阶段的AXI数据宽度；P3将拆成正式memory AXI与ysyxSoC边界宽度 | 32 |
| `ARCH_REG_COUNT` | 架构整数寄存器数量 | 32 |

## 2. 配置机制

SystemVerilog package不能像module一样按实例参数化，而payload类型又必须在编译时拥有确定
位宽。因此本项目只支持经过验证的命名配置，不承诺任意参数组合：

1. 编译配置层选择且只选择一个命名配置；
2. 配置package导出宽度和容量常量；
3. ISA/payload package导入配置package并定义共享类型；
4. 功能模块只使用语义常量和`$bits(type)`，不自行定义另一套宽度；
5. 不同命名配置分别构建和回归，禁止在时序逻辑中根据配置运行时切换。

首个命名配置保持当前行为：`YSYX_RV32_BASELINE`。第二个配置只在P3加入：
`YSYX_RV64_SEQUENTIAL`。

## 3. 不变量

- `INSTR_WIDTH`与`XLEN`独立；迁移到RV64后基础指令仍为32位。
- core本地访存接口与AXI接口独立；宽度转换只属于明确的adapter。
- AXI每个channel继续独立握手，配置层不能改变协议语义。
- 地址切片由拥有该结构的模块从参数派生，不能散落硬编码`31`、`32`或固定lane数量。
- RV32基线在每个迁移检查点都必须可lint并通过dummy，不能等全部替换后再回归。

## 4. 实施顺序

### P2-A：宽度依赖审计

建立清单，区分以下三类常量：

1. ISA固定值，例如32位基础指令编码和opcode宽度；
2. 命名配置值，例如`XLEN`、物理地址宽度和AXI数据宽度；
3. 模块局部派生值，例如cache tag、set index、byte lane和AXI size。

优先审计`common` package、寄存器堆、IDU/EXU/LSU/CSR、I-cache、AXI边界和DPI/仿真模型。
注释、断言和打印格式也属于审计范围。

第一轮结果见[`P2_WIDTH_AUDIT.md`](P2_WIDTH_AUDIT.md)。该清单已经识别公共package、
I-cache、CSR/PMU、LSU和AXI边界的首批耦合点；P2-B必须按清单逐项迁移。

### P2-B：创建配置package

新增唯一配置package，将当前`riscv32_pkg`中的宽度/容量配置迁入；`riscv32_pkg`只保留
ISA常量、语义枚举和模块间payload。迁移一项就删除旧定义，不保留兼容别名。

已创建`common/riscv_config_pkg.sv`并加入仿真与STA filelist。配置package现在是全局构建
参数的唯一来源；`riscv32_pkg`、地址映射package和AXI4 package只保留各自拥有的语义类型
与派生量。旧宽度定义和兼容别名已经删除，独立NPC与ysyxSoC lint均已通过。

### P2-C：解耦core内部宽度

依次修改寄存器堆、decode/execute、CSR/trap、LSU和前端。每个模块使用语义类型，load/store
的size、符号扩展和byte enable必须由宽度派生。完成一个边界就运行lint和dummy。

已完成寄存器堆、IDU/EXU、CSR/trap、PMU、LSU、IFU和I-cache内部数据通路的语义类型
迁移。PC、标量数据、物理地址、指令和I-cache取指数据不再依靠相同的裸位宽表达；跨地址
package和总线边界时使用显式类型转换。本检查点已通过独立NPC的lint、build和dummy回归。

### P2-D：解耦cache和互连宽度

I-cache line几何与`INSTR_WIDTH`关联，不能默认等于`XLEN`。AXI package使用独立的地址、
数据、ID和strobe宽度。core到AXI的宽度变化只在adapter中完成。

已完成I-cache与互连的宽度解耦。cache word、line、set和tag切片由取指宽度、物理地址宽度
及cache参数派生；AXI4各通道使用独立的地址、数据、ID和strobe类型。uncached adapter是
core访存宽度与AXI数据宽度之间唯一的转换边界，负责窄beat拆分、读数据合并、写数据和
strobe切片以及错误聚合。I-cache refill adapter也按AXI beat宽度选择返回lane，不再假定
取指word和AXI beat等宽。

### P2-E：建立宽度adapter单元测试

先验证64位core侧到32位AXI侧的拆分/合并，不立即接入RV64 core。测试至少覆盖：

- 对齐的64位读写拆成两个32位beat；
- byte/half/word写的地址和strobe；
- AXI反压和错误响应；
- 第二个beat失败时只返回一次core错误；
- valid有效且ready无效时payload稳定。

已建立64位core侧到32位AXI侧的自检单元测试，覆盖对齐64位读写、byte/half/word写、
AW/W独立反压、读写错误传播、第二个读beat失败、写响应失败以及响应背压稳定性。adapter
对一次core请求只产生一次完成响应。

P3对该测试的架构定位作如下收窄：它验证的是`AXI64 -> AXI32`的ysyxSoC集成边界，不是
正式RV64 memory AXI。RV64 core/cache侧的正式memory AXI采用64位数据宽度；只有接入当前
固定AXI32的ysyxSoC时才实例化该转换器。

## 5. P2退出条件和验证结果

- [x] 活动RTL不存在把`XLEN`、地址宽度、指令宽度和AXI宽度默认等同的接口；
- [x] `YSYX_RV32_BASELINE`完成lint、dummy和35项cpu-tests回归；
- [x] 使用standalone内存配置的NEMU reference完成dummy DiffTest；
- [x] 64位core侧到32位AXI侧的宽度adapter单元测试通过；
- [x] 文档记录剩余固定宽度及其明确所有者；
- [x] P3开始前冻结`YSYX_RV64_SEQUENTIAL`的ISA、软件和DiffTest范围。

| 检查项 | 命令或配置 | 结果 |
| --- | --- | --- |
| RTL lint | `make lint-npc PROJECT=riscv32` | 通过，仅剩未使用配置/地址常量提示 |
| adapter单元测试 | `make test-width-adapter PROJECT=riscv32` | 通过 |
| RV32功能回归 | 逐项运行35个`cpu-tests`镜像 | 35/35通过 |
| DiffTest | dummy + standalone NEMU reference | 通过，13条退休指令 |

DiffTest复验时必须区分两类NEMU reference：ysyxSoC配置使用`0x2000_0000`附近的SoC内存
映射，独立NPC配置使用`0x8000_0000`基址。P2验证在临时目录中构建standalone reference，
没有覆盖工作区当前的ysyxSoC NEMU配置。

## 6. 下一个实际任务

P3首版范围已经冻结，后续工作按
[`P3_RV64_SEQUENTIAL_PLAN.md`](P3_RV64_SEQUENTIAL_PLAN.md)执行。文件和module名称暂不做
全局`riscv32`到`riscv64`替换；先让同一实现通过两个命名配置，再依据模块实际职责统一命名。
