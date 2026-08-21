# NPC微架构实验日志

本文件只允许追加。每个结果必须记录Git commit、构建配置、工作负载、精确命令和相关
架构决策。若某项结果后来被证明无效，应追加一条记录解释原因，不能删除旧记录。

## 结果模板

### YYYY-MM-DD - <实验名称>

- Commit：`<完整commit hash或uncommitted>`
- 架构决策：`<Dxxx>`
- 工作负载和规模：`<名称>` / `<规模>`
- 构建配置：`<重要参数和功能开关>`
- 命令：`<精确命令>`
- 功能结果：`<pass/fail和trap状态>`
- 综合目标/结果：`<工艺、目标时钟、WNS/TNS/面积等>`

| 指标 | 数值 |
| --- | ---: |
| 活动周期 | |
| 退休指令数 | |
| IPC | |
| I-cache lookup/hit/miss | |
| I-cache命中率 | |
| IFU平均响应延迟 | |
| IFU响应等待周期 | |

分析：

- 说明相对上一条可比较记录发生了什么变化。
- 指出测得的主要瓶颈。
- 分开记录测量事实和待验证假设。
- 给出能够证实或否定假设的下一项实验。

## 2026-07-30 - 接入I-cache前的microbench基线

- Commit：uncommitted；在正式比较前必须基于已提交版本重新运行并追加基线记录。
- 架构决策：当前计划P1开始之前（历史计划D024之前）。
- 工作负载和规模：microbench / test。
- 构建配置：ysyxSoC校准延迟环境，未实现I-cache。
- 命令：历史运行；基于commit重新运行时必须记录准确命令。
- 功能结果：正常结束并输出性能统计。
- 综合目标/结果：本次运行不包含综合结果。

| 指标 | 数值 |
| --- | ---: |
| 活动周期 | 118,497,980 |
| 退休指令数 | 821,857 |
| IPC | 0.006936 |
| IFU请求/响应/交付 | 821,857 / 821,857 / 821,857 |
| IFU平均响应延迟 | 136.645 cycles |
| IFU AR反压周期 | 5,373,567 (4.535%) |
| IFU响应等待周期 | 112,302,555 (94.772%) |
| LSU load平均延迟 | 79.295 cycles |
| LSU store平均延迟 | 59.978 cycles |

分析：

- 前端响应等待区间占活动周期的94.772%。
- 第一项I-cache实验必须使用相同工作负载和延迟配置进行比较。
- 核心验收指标是更少的IFU响应等待周期和更高的IPC，并使用cache hit/miss/refill
  计数器解释变化原因。
- 由于没有记录commit和准确命令，本条记录不可完全复现，只保留为初步基线。

## 2026-08-13 - P1 I-cache独立NPC基本功能检查

- Commit：待提交工作树，基于`22f2b42ca794b2c4d7dc84b8f4c74d56304ed3c9`；提交后追加
  可复现commit记录。
- 架构决策：P1、D004、D005。
- 工作负载和规模：cpu-tests dummy / 13条退休指令。
- 构建配置：独立NPC，8 KiB、2-way、32 B line、blocking miss、AXI4 refill、I-cache启用。
- 命令：`make sim-npc PROJECT=riscv32 IMG=../am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin`
- 功能结果：pass，`HIT GOOD TRAP`，结束PC为`0x80000030`。
- 综合目标/结果：本次运行不包含综合结果。

| 指标 | 数值 |
| --- | ---: |
| 活动周期 | 71 |
| 退休指令数 | 13 |
| IPC | 0.183099 |
| IFU请求/响应/交付 | 17 / 16 / 13 |
| IFU平均响应延迟 | 2.500 cycles |
| IFU AR反压周期 | 14 (19.718%) |
| IFU响应等待周期 | 40 (56.338%) |
| IFU下游反压周期 | 1 (1.408%) |
| IFU丢弃错误路径响应 | 3 |
| LSU请求/完成 | 1 / 1 |

分析：

- 该结果证明当前活动RTL能够经过I-cache和fetch buffer完成基本程序，并正确丢弃redirect
  后的错误路径响应。
- dummy太短，不能用其IPC、命中率或平均延迟判断I-cache性能，也不能覆盖替换、early
  restart、错误refill和`fence.i`。
- 下一项实验是在提交版本上重跑相同命令，并完成I-cache定向测试和microbench A/B。

## 2026-08-13 - P1 I-cache提交版本复验

- Commit：`ce27fb8eed29c0b039dc11ddc66407c096486a16`。
- 架构决策：P1、D004、D005。
- 工作负载和规模：cpu-tests dummy / 13条退休指令。
- 构建配置：独立NPC，8 KiB、2-way、32 B line、blocking miss、AXI4 refill、I-cache启用。
- 命令：`make sim-npc PROJECT=riscv32 IMG=../am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin`
- 功能结果：pass，`HIT GOOD TRAP`，结束PC为`0x80000030`。
- 静态检查：`make lint-npc PROJECT=riscv32`和`make lint-soc PROJECT=riscv32`均通过；
  剩余信息为未使用地址常量和ysyxSoC既有时序风格警告。
- 综合目标/结果：本次运行不包含综合结果。

| 指标 | 数值 |
| --- | ---: |
| 活动周期 | 71 |
| 退休指令数 | 13 |
| IPC | 0.183099 |
| IFU请求/响应/交付 | 17 / 16 / 13 |
| IFU平均响应延迟 | 2.500 cycles |
| IFU AR反压周期 | 14 (19.718%) |
| IFU响应等待周期 | 40 (56.338%) |
| IFU下游反压周期 | 1 (1.408%) |
| IFU丢弃错误路径响应 | 3 |
| LSU请求/完成 | 1 / 1 |

分析：

- 该记录把P1基本功能检查绑定到确定提交，可由相同命令复现。
- 结果只证明最短控制流、一次store、redirect响应丢弃以及I-cache基本取指路径可工作；P1仍需
  I-cache定向测试、完整功能回归、microbench A/B和综合/STA后才能关闭。

## 2026-08-14 - P2配置层和宽度解耦收口

- Commit：uncommitted；P2提交后应把本字段替换为确定commit。
- 架构决策：P2，core宽度和AXI宽度只在adapter边界转换。
- 工作负载和规模：64/32位宽度adapter定向测试、35项RV32 cpu-tests、dummy DiffTest。
- 构建配置：`YSYX_RV32_BASELINE`；adapter单测额外启用64位core/32位AXI测试配置。
- 命令：`make test-width-adapter PROJECT=riscv32`、`make lint-npc PROJECT=riscv32`；
  cpu-tests逐镜像运行；DiffTest使用standalone内存配置的临时NEMU reference。
- 功能结果：adapter测试通过，lint通过，cpu-tests 35/35通过，dummy DiffTest通过。
- 综合目标/结果：本次变更不包含新的综合/STA结果。

验证范围：

- adapter覆盖64位读写拆成两个32位beat、窄写strobe、AW/W独立反压和响应保持；
- 覆盖读beat错误、第二个读beat错误和写响应错误，均只向core返回一次错误；
- RV32完整cpu-tests证明宽度重构没有破坏现有指令行为；
- standalone DiffTest证明重构后的架构状态仍与NEMU一致。

分析：

- P2的主要风险不是算术逻辑，而是地址lane、strobe、burst终止和错误聚合边界；定向单元
  测试比仅运行短程序更能约束这些行为。
- ysyxSoC与独立NPC使用不同NEMU内存映射，不能复用同一个reference构建结果。后续应在
  P3回归脚本中把两种reference配置显式命名，避免环境配置被误判为RTL错误。

## 2026-08-20 - P3-B RV64I译码语义验证

- Commit：uncommitted；当前基于`a6f6cc06c0337a58209337bab289c0d3a79c8596`。
- 架构决策：P3-B；IDU是指令编码到micro-op语义的唯一所有者。
- 工作负载和规模：RV32/RV64 directed decode test。
- 构建配置：`rv32-baseline`和`rv64-sequential`。
- 命令：`make test-idu-configs PROJECT=riscv32`、`make lint-configs PROJECT=riscv32`。
- 功能结果：两套定向测试通过；两套配置lint无语法或elaboration错误。
- 综合目标/结果：本次检查点不包含综合结果。

验证范围：

- RV64覆盖`ADDIW/SLLIW/SRLIW/SRAIW`、`ADDW/SUBW/SLLW/SRLW/SRAW`、
  `LWU/LD/SD`；
- 覆盖普通RV64移位量32和63、非法`*IW shamt[5]`、非法`OP-32 funct3`以及
  `LUI/AUIPC`符号扩展；
- RV32明确拒绝RV64专属opcode、访存宽度和6位移位量；
- 非法指令检查`mtval`并确认没有寄存器写、访存、CSR写或redirect副作用。

分析：

- 本结果只冻结译码输出契约，不代表RV64指令已经能够端到端执行。
- P3-C需要消费独立的`ALU_*W`操作并显式实现低32位运算后符号扩展；P3-D再实现
  `LWU/LD/SD`的数据通路和AXI宽度边界。

## 2026-08-20 - P3-C RV64 EXU word运算验证

- Commit：uncommitted；沿用P3-B工作树。
- 架构决策：P3-C；`*W`是独立语义操作，由EXU显式执行32位运算和符号扩展。
- 工作负载和规模：RV32/RV64 directed EXU ALU test。
- 构建配置：`rv32-baseline`和`rv64-sequential`。
- 命令：`make test-exu-configs PROJECT=riscv32`、`make lint-configs PROJECT=riscv32`。
- 功能结果：两套定向EXU测试通过；两套配置lint无语法或elaboration错误。
- 综合目标/结果：本检查点不包含综合结果。

验证范围：

- 覆盖`ADDW/SUBW/SLLW/SRLW/SRAW`、ADDIW对应的立即数操作数路径、负数和32位
  溢出回绕；
- 覆盖`*W`移位量31/32/63，确认寄存器移位只消费低5位；
- 覆盖普通RV64移位量32/63，确认其6位移位量没有被`*W`规则污染；
- RV32覆盖原有加减、移位和有符号比较，检查P3-C没有改变基线结果。

分析：

- 显式32位中间结果使word语义不依赖SystemVerilog上下文宽度和隐式截断，后续拆分
  integer ALU时仍可直接复用；
- 本检查点只关闭EXU算术语义，RV64访存、CSR和端到端程序执行仍属于后续阶段。

## 2026-08-20 - P3-D RV64 LSU与AXI宽度边界验证

- Commit：uncommitted；沿用P3-C工作树。
- 架构决策：正式core memory AXI与core数据同宽；ysyxSoC AXI32限制只在system wrapper
  转换；MMIO不允许隐式拆分。
- 工作负载和规模：LSU、uncached AXI4 adapter、AXI64到ysyxSoC AXI32 converter定向测试，
  双配置完整构建，RV32 dummy。
- 构建配置：`rv32-baseline`和`rv64-sequential`。
- 综合目标/结果：本检查点不包含综合结果。

验证命令：

```sh
make test-lsu-configs PROJECT=riscv32
make test-uncached-configs PROJECT=riscv32
make test-soc-width-converter PROJECT=riscv32 NPC_CONFIG=rv64-sequential
make lint-configs PROJECT=riscv32
make lint-soc PROJECT=riscv32 NPC_CONFIG=rv64-sequential
make build-npc PROJECT=riscv32 NPC_CONFIG=rv32-baseline
make build-npc PROJECT=riscv32 NPC_CONFIG=rv64-sequential
make sim-npc PROJECT=riscv32 NPC_CONFIG=rv32-baseline \
  IMG=../am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin SIM_ARGS=--batch
```

验证结果：

- `LB/LBU/LH/LHU/LW/LWU/LD`、`SB/SH/SW/SD`及自然对齐异常测试通过；
- uncached adapter在32/64位下均通过AR反压、AW/W独立握手、响应保持和错误映射测试；
- 边界转换器通过窄访问lane、64位读写拆分、第二个read beat错误聚合、B反压以及宽MMIO
  本地`DECERR`测试；
- 两套standalone配置完整编译和链接成功，RV64 ysyxSoC lint成功；
- RV32 dummy在PC `0x80000030`命中good trap，退休13条指令，运行71周期。

分析：

- core、正式memory AXI和特定SoC端口的宽度责任已经分离；后续自研64位SoC不需要继承
  ysyxSoC的32位拆分开销；
- 对宽MMIO先拒绝再返回错误，避免第一次32位子事务已产生设备副作用后才发现访问非法；
- 当前RV64构建中的PC/GPR仿真DPI仍为32位，该软件调试接口由P3-F统一升级，不影响本阶段
  RTL访存与协议边界的退出条件。

## 2026-08-20 - P3-E RV64 CSR、精确异常与提交验证

- Commit：uncommitted；沿用P3-D工作树。
- 架构决策：CSR先产生写意图，只有commit才能改变架构状态；`minstret`由commit驱动。
- 工作负载和规模：RV32/RV64 privileged directed test、EXU未对齐跳转回归。
- 构建配置：`rv32-baseline`和`rv64-sequential`。
- 命令：`make regression-p3-e PROJECT=riscv32`。
- 功能结果：双配置特权级测试和EXU测试全部通过。
- 综合目标/结果：本检查点不单独记录综合结果，由P3-G统一建立基线。

验证范围：

- CSR地址合法性、只读检查、`mstatus/mie/mtvec/mepc/mip`的WARL行为；
- `ecall/mret`、非法指令、取指/访存access fault和未对齐异常；
- trap指令不写GPR、不发起存储器请求，错误CSR写不产生架构副作用；
- RV64 CSR整宽访问和RV32计数器高低半访问保持各自语义。

分析：

- ECALL不携带故障地址或故障指令，因此`mtval`必须为零；该端到端检查修复了
  IDU继承IFU默认`exception_tval=pc`的错误。
- commit与执行完成分离后，后续流水化可以保持精确异常和准确的`minstret`语义。

## 2026-08-20 - P3-F RV64软件、NEMU reference与DiffTest验证

- Commit：uncommitted；沿用P3-E工作树。
- 架构决策：AM、NPC仿真器和NEMU参考模型共享一个按XLEN选择的架构状态契约。
- 工作负载和规模：RV32/RV64各35项cpu-tests，所有测试都启用DiffTest。
- 构建配置：`rv32-baseline`和`rv64-sequential`；NEMU分别构建RV32/RV64 reference。
- 命令：`make regression-p3-f-rv32 PROJECT=riscv32`、
  `make regression-p3-f-rv64 PROJECT=riscv32`。
- 功能结果：RV32 35/35通过，RV64 35/35通过；`csr-trap`通过ECALL到`mret`闭环。
- 综合目标/结果：本检查点不单独记录综合结果，由P3-G统一建立基线。

验证范围：

- AM使用RV64I+Zicsr+Zifencei/LP64工具链参数，启动和trap汇编按XLEN共享；
- NPC DPI和DiffTest比较GPR、PC以及`mstatus/mtvec/mepc/mcause/mtval`；
- cpu-tests覆盖算术、长整数、移位、分支、负载存储、字符串、排序、递归和CSR/trap；
- `unalign`不加入回归，因为它要求透明完成非对齐访存，与当前硬件契约不同。

分析：

- RV64 `hello-str`通过后，确认AM已使用RV64软除法路径，不再误入32位C软除法的递归；
- RV32/RV64 reference分离生成和显式选择，避免NEMU最近一次menuconfig结果污染另一配置的
  DiffTest。

## 2026-08-20 - P3-G RV64多周期功能基线

- Commit：uncommitted；P3-G实现和验证已完成，创建基线提交前不得开始P3-H。
- 架构决策：同一份RTL必须同时维持RV32课程基线和RV64顺序基线；ysyxSoC的AXI32限制只
  保留在system width-converter边界。
- 工作负载和规模：双配置模块定向测试、RV32/RV64各35项cpu-tests DiffTest、standalone
  与ysyxSoC lint、完整core综合和STA。
- 构建配置：`rv32-baseline`和`rv64-sequential`。
- 命令：`make regression-p3-g PROJECT=riscv32`。
- 功能结果：统一回归命令退出码为0；RV32 35/35、RV64 35/35 DiffTest通过，全部定向测试、
  lint和构建通过。

PMU基线（`hello-str`）：

| 配置 | 退休指令 | CPU周期 | IPC | IFU平均响应延迟 | load平均延迟 | store平均延迟 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| RV32 | 1862 | 7011 | 0.265583 | 2.139 cycles | 3.132 cycles | 3.000 cycles |
| RV64 | 1876 | 7100 | 0.264225 | 2.148 cycles | 3.131 cycles | 3.000 cycles |

综合与STA基线（300 MHz，I-cache SRAM array作为黑盒）：

| 配置 | 标准单元面积 | 时序单元面积 | WNS | TNS | 报告频率 | 关键终点 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| RV32 | 38183.32 | 18138.12 | +0.068 ns | 0.000 ns | 306.307 MHz | I-cache替换状态 |
| RV64 | 58743.44 | 27738.76 | -0.366 ns | -114.307 ns | 270.373 MHz | 架构寄存器堆写回 |

分析：

- RV64逻辑壳面积相对RV32增加约53.85%，时序单元面积增加约52.93%，报告频率下降约
  11.73%；64位寄存器状态和写回选择路径已经成为P3-H必须处理的物理代价；
- 两套配置的`hello-str` IPC均约0.265，说明当前主要吞吐限制是多周期处理器把取指、执行和
  访存串行化，而不是RV64语义本身；
- PDK不包含I-cache SRAM macro和Liberty模型，因此面积、WNS和频率仅描述逻辑壳。获得真实
  cache时序前必须替换tag/data array并补充macro时序弧；
- AXI反压测试是固定、可复现的五通道定向序列，不把尚未建立的随机验证环境记为已覆盖。

## 2026-08-21 - NEMU itrace驱动的I-cache设计空间探索链路

- Commit：uncommitted；沿用当前I-cache与P3工作树。
- 工作负载：`bubble-sort-riscv32-npc.bin`和`crc32-riscv32-npc.bin`。
- 模型：精确LRU组相联Cache；相同容量的全相联LRU Shadow Cache负责3C分类。
- 扫描范围：4/8/16/32KiB，16/32/64B line，1/2/4-way，共36组。
- 命令：`make cachesim-test`、`make cachesim-trace`、`make cachesim-explore`。

验证结果：

- 三组确定性测试覆盖conflict miss、capacity miss以及NEMU/NPC文本trace解析，全部通过；
- NEMU正确运行RV32I `bubble-sort`并在PC `0x80000140`命中good trap，生成2798条PC记录；
- NEMU正确运行RV32I `crc32`并在PC `0x8000012c`命中good trap，生成13277条PC记录；
- `crc32`在8KiB、2-way、32B line下为10次compulsory miss，Hit Rate为99.9246818%；
- 使用当前32B line实测常数284.142 cycles估算，AMAT为2.214010695 cycles，TMT为
  2841.42 cycles。

分析：

- 当前两个cpu-test的指令工作集远小于4KiB，只能验证工具链，不能形成容量或路数决策；
- 64B line在统一miss penalty假设下miss更少，不代表真实收益，因为其完整refill代价尚未
  由RTL校准；
- 下一轮必须获取目标AI工作负载的长trace，并分别校准不同line大小的miss penalty，再把
  少量候选方案送回RTL、综合和STA验证。

## 2026-08-21 - RV64 MicroBench I-cache参数扫描

- Commit：uncommitted；沿用当前I-cache、P3和cachesim工作树。
- 工作负载：RV64 MicroBench `test`，10个子测试全部通过。
- 动态指令：完整程序723827条；PMU benchmark窗口退休276790条。
- 扫描范围：1/2/4/8/16/32KiB，16/32/64B line，1/2/4-way，共54组。
- 输出：`result/cache/cachesim_riscv64_microbench_test_exploration.csv`。

为生成trace补充的reference能力：

- NEMU实现XLEN通用的`MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU`；
- RV64实现`MULW/DIVW/DIVUW/REMW/REMUW`及32位结果符号扩展；
- 除零、最小负数除以`-1`、高位乘法和W类边界定向测试通过；
- NEMU增加`mcycle/minstret`模型；MicroBench按XLEN选择RV32高低半读取或RV64整宽读取。

关键结果（32B line）：

| 容量/路数 | Miss | Compulsory | Capacity | Conflict |
| --- | ---: | ---: | ---: | ---: |
| 1KiB/1-way | 1674 | 555 | 748 | 371 |
| 1KiB/4-way | 1421 | 555 | 812 | 54 |
| 8KiB/1-way | 686 | 555 | 6 | 125 |
| 8KiB/2-way | 590 | 555 | 10 | 25 |
| 8KiB/4-way | 572 | 555 | 10 | 7 |
| 32KiB/任意路数 | 555 | 555 | 0 | 0 |

分析：

- 相联度提升明确降低conflict miss；8KiB从1-way到2-way减少96次miss，从2-way到4-way
  只再减少18次，已出现边际收益下降；
- 32KiB可容纳本次执行触达的全部32B指令line，因此只剩555次compulsory miss；
- 8KiB、2-way下16/32/64B line的refill流量为18160/18880/20224B，不能只看miss次数；
- 当前统一使用32B RTL测得的284.142 cycles penalty。正式选择line大小前必须分别校准
  16/32/64B refill时延，并补充面积、命中路径时序和目标AI workload。
