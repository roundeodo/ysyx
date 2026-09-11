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
- 本轮统一使用32B RTL测得的284.142 cycles penalty。正式选择line大小前必须分别校准
  16/32/64B refill时延，并补充面积、命中路径时序和目标AI workload。

## 2026-08-21 - I-cache line大小与refill事务组织探索

- Commit：uncommitted；沿用当前P3、I-cache和cachesim工作树。
- 工作负载：RV64 MicroBench `test`。
- 几何范围：1/2/4/8/16/32KiB，16/32/64B line，1/2/4-way。
- 传输模型：4B beat；独立读事务与AXI4 INCR burst；归一化`a=b=c=d=1`。
- 输出：`cachesim_riscv64_independent_exploration.csv`、
  `cachesim_riscv64_burst_exploration.csv`和
  `cachesim_riscv64_rtl_calibrated_exploration.csv`。

实现和验证：

- cachesim逐次miss记录critical word位于line中的第几个beat，分别计算critical TMT、
  complete refill占用、AXI读事务数、beat数和传输字节；
- RTL通过`NPC_ICACHE_LINE_BYTES`构建参数选择line大小，16/64B在RV32和RV64共四种组合下
  lint通过，四种dummy smoke test均命中good trap；
- RV64 MicroBench在16/32/64B line下均10/10通过；关键字附加代价分别为
  4.178/4.625/5.964周期，完整refill分别为6.043/10.017/18.006周期；
- 8KiB、2-way的NEMU trace中，独立事务模型下16/32/64B critical TMT为
  5244/3736/3864；burst模型下降为4716/2704/1914；
- RTL测量窗口周期为1432513/1431536/1431192，64B最低，但相对32B只降低344周期。

结论：

- 更大line只有配合burst才能避免重复支付每个word的事务建立开销；
- 当前升序burst和critical-word early restart能够让IFU在整行完成前获得目标指令；
- 64B在本工作负载上TMT最低，但系统周期收益约0.024%，不能忽略SRAM面积和时序成本；
- 本次只完成line大小和传输组织探索，尚未形成最终I-cache参数决策。

## 2026-08-21 - cachesim比较口径修正

- 问题：初次汇总把历史`fixed=284.142 cycles`、归一化`a=b=c=d=1`传输模型和standalone
  RTL实测结果放在同一张表中比较绝对AMAT/TMT。三者的时间模型和存储环境不同，该比较
  无效。
- 修正：`make cachesim-explore`恢复以`fixed`作为默认模型；独立事务和burst只能通过
  `make cachesim-explore-transport`显式运行。
- 回归：使用相同RV64 MicroBench trace、相同54组Cache几何和相同`284.142 cycles`固定
  代价重跑，新旧CSV在miss分类、命中率、AMAT、TMT和refill字节数上逐项比较，差异数为0。
- 比较规则：`fixed`只用于历史回归；归一化模型只允许在相同`a/b/c/d`下比较传输组织；
  standalone RTL只允许在相同顶层、存储模型、workload和统计窗口下比较line大小。
- 有效结论：16/32/64B standalone RTL结果之间的比较仍然有效；归一化模型能够说明burst
  如何减少重复事务建立开销；二者都不能与旧`284.142 cycles`结果计算提升比例。

## 2026-08-21 - ysyxSoC AXI SDRAM与I-cache burst联调

- ysyxSoC启用AXI SDRAM控制器，CPU BlackBox直接实例化`riscv32_npc_axi`；
- 仿真平台用两个并行x16 SDRAM颗粒形成32-bit数据口，`DQ`和`DQM`分别扩展为32位和4位；
- 增加`icache-sdram-burst-test`：先向`0xa0000000`写入两条指令，执行`fence.i`后跳到
  SDRAM取指并检查返回值；
- 修复SDRAM控制器将一个AXI写beat重复发出两条WRITE命令的问题；
- 修复SDRAM行为模型在返回最后一个读beat时丢弃同周期下一条流水化READ命令的问题。

验证结果：

- `icache-sdram-burst-test`和原有`sdram-test`均命中good trap；
- SoC lint通过，仅保留既有的非致命告警；
- 波形确认对`0xa0000000`只发生一次AXI AR握手，`ARLEN=7`、`ARBURST=INCR`；
- 随后完成8次R握手，前两拍为`0x02a00513`和`0x00008067`，最后一拍`RLAST=1`；
- 当前是AXI层8-beat burst。SDRAM Mode Register仍配置BL1，控制器在打开行上调度8条
  单beat READ命令；原生SDRAM BL8属于后续独立优化，不能与本次AXI burst混为一谈。

## 2026-08-21 - AXI读事务到SDRAM原生BL8的通用分段

- AXI-to-SDRAM边界开始接收`ARSIZE/AWSIZE`，地址步进不再隐含固定4B；
- 分段器完全按AXI事务属性工作，不依赖请求来自I-cache、未来D-cache还是其他manager。
  对32-bit INCR读，32B对齐且至少剩余8 beat时发一条原生BL8；未对齐头部和不足8 beat
  的尾部使用单拍，从而支持任意长度和任意word对齐起点；
- 一个AXI读事务可映射为多个物理SDRAM段。事务级状态统一保持原始ID、总beat数和唯一的
  最终`RLAST`，物理段状态只选择下一条单拍或BL8命令；
- Mode Register配置为读BL8、写single-beat。其他读事务仍逐beat调度，并在取得所需
  单个beat后发送`BURST TERMINATE`，避免固定BL8列地址回绕改变AXI地址序列；
- 原生burst的返回beat先进入16深度响应FIFO。发出每个物理段前按FIFO占用量做信用检查，
  因此SDRAM连续返回不受AXI `RREADY`反压影响；16项刚好可以完整缓存64B/32-bit事务，
  更长事务会在段边界等待FIFO释放空间；
- 当前写路径尚未把完整W burst预先缓存，所以不伪装支持原生BL8写。未来D-cache脏行
  写回需要在同一事务分类器下增加写burst buffer。

验证结果：

- `make test-sdram-axi`通过：32B对齐事务产生1条READ且不产生TERMINATE；64B对齐事务
  产生2条READ且不产生TERMINATE；从32B边界后4B开始的64B事务被拆为7个头部单拍、
  1个BL8和1个尾部单拍，共9条READ和8条TERMINATE；
- 上述事务均在`RREADY`连续拉低20周期时保持数据顺序、AXI ID和唯一的最终`RLAST`；
- 32B和64B I-cache配置的`icache-sdram-burst-test`均命中good trap；4KiB `sdram-test`
  同样通过，字节和半字写掩码没有回归；
- 波形中`0xa0000000`的refill只出现1条SDRAM READ命令，8个AXI响应beat连续返回；
- response beat索引在仿真时间`21017..21031`按一个CPU周期递增，旧BL1基线约每两个
  CPU周期返回一个beat，完整32B读取的尾部缩短约7个CPU周期；
- 单beatSDRAM回归出现1026条READ和1026条BURST TERMINATE，证明短事务没有误收
  固定BL8的剩余数据。

## 2026-08-21 - AXI事务延迟校准模块

- 将`ysyxSoC/perip/amba/axi4_delayer.v`从直通连接改为事务级延迟校准器，默认频率比为
  `3037 / 1024`。读事务与写事务使用独立计时状态，允许一笔读和一笔写同时进行；
- 计时起点是上游第一次拉高`ARVALID`，或`AWVALID/WVALID`中最早出现的时刻，而不是
  地址握手时刻。因此等待下游`READY`的时间也被纳入设备访问时间；
- R通道为每个返回beat分别计算目标上游周期，并保存ID、数据、响应状态、`RLAST`和目标
  周期。16项响应FIFO能够覆盖64B cache line在32-bit AXI上的16个beat，也允许下游在
  上游尚未到目标时刻时继续返回数据；
- 若响应到达时已经满足目标周期且FIFO为空，则使用直接路径同周期返回，不固定增加一拍；
- AW和W握手分别记录，支持二者任意先后到达。当前写路径校准整笔事务的B响应；尚未实现
  D-cache脏行写回，因此不把W burst逐beat校准记为已完成；
- 当前每个方向最多一笔未完成事务，不支持同方向多ID并发。该限制符合当前顺序核，但未来
  流水化访存和多未决miss需要用按ID/事务项保存起点与目标时刻的队列替换单事务状态。

验证结果：

- `make test-axi-delayer`通过。定向测试使用精确2:1频率比，让写事务与尚未结束的16-beat
  读突发重叠；每个读beat均满足`upstream - start = 2 * (downstream - start)`，且W先于
  AW握手时写事务仍从最早出现的VALID开始计时；
- ysyxSoC完整lint和RV32仿真构建通过，仅保留工程既有非致命告警；
- `icache-sdram-burst-test`命中good trap，15次refill的平均critical响应延迟为16.600
  周期，平均完整回填延迟为49.000周期；
- 同一测试在64B I-cache line配置下也命中good trap，9次refill的平均critical响应延迟为
  26.889周期，平均完整回填延迟为95.556周期，覆盖了16项R响应FIFO的全部深度；
- 4KiB `sdram-test`通过字、字节和半字写掩码检查并命中good trap。该测试的I-cache平均
  完整回填延迟为48.782周期，LSU AXI读/写响应平均延迟为8.794/6.104周期。

## 2026-08-21 - MicroBench train原生SDRAM BL8严格A/B评估

实验控制变量：

- 工作负载统一为同一份`riscv32-ysyxsoc-sdram` MicroBench `train`镜像；
- CPU配置统一为`rv32-baseline`，I-cache为32B line，AXI延迟校准参数保持不变；
- 唯一变量是`NPC_SDRAM_NATIVE_READ_BURST`：`0`将一个AXI burst拆成8个独立SDRAM
  BL1读，`1`将满足条件的32B段映射为一条原生SDRAM BL8；
- 两组10个子测试均通过，MicroBench测量窗口退休指令均为186810217条。

结果：

| 指标 | BL1基线 | 原生BL8 | 变化 |
| --- | ---: | ---: | ---: |
| MicroBench测量窗口周期 | 902867825 | 902833775 | -34050 (-0.00377%) |
| MicroBench测量窗口IPC | 0.206907 | 0.206915 | +0.00377% |
| 全程CPU周期 | 1239931108 | 1239853749 | -77359 (-0.00624%) |
| I-cache miss | 725 | 725 | 不变 |
| 平均critical响应延迟 | 46.021 | 33.212 | -27.83% |
| 平均miss penalty | 44.021 | 31.212 | -29.10% |
| 平均完整refill延迟 | 154.618 | 48.708 | -68.50% |
| lookup请求等待周期 | 81167 | 13668 | -83.16% |
| 全程critical TMT估算 | 31915.225 | 22628.700 | -9286.525 (-29.10%) |
| 全程精确AMAT估算 | 2.000094 | 2.000067 | -0.000027周期 |

分析：

- 原生BL8显著减少SDRAM命令建立和整行回填时间，说明物理传输优化真实有效；
- 725次miss相对于约3.38亿次lookup极少，命中率约99.9998%，因此miss penalty即使下降
  29%，AMAT和应用IPC也几乎不变；本工作负载已不能继续放大I-cache refill优化收益；
- critical-word early restart使CPU无需等待完整cache line返回。完整refill缩短68.50%，
  但大部分尾部传输处于关键字交付后的后台路径，因此不能等比例转化为总周期下降；
- MicroBench PMU窗口只覆盖各benchmark的`run()`，I-cache统计覆盖启动、准备、打印和
  benchmark全程。因此全程TMT不能直接与PMU窗口减少的34050周期逐项相减；
- 后续若要评估burst的应用收益，应使用指令工作集超过I-cache容量、或人为缩小I-cache的
  压力工作负载；当前结果更适合证明传输机制正确，以及表明性能瓶颈不在I-cache miss。

实现中发现并修复的协议问题：满足原生burst分类条件但响应FIFO暂时没有足够空间时，
必须通过`ARREADY`反压等待，不能临时降级为普通首beat。错误降级会使事务只返回一个
非末beat且永远等不到`RLAST`。修复后`make test-sdram-axi`、`make test-axi-delayer`和
两组MicroBench均通过。

## 2026-08-21 - I-cache逐line RTL缺失代价自动校准

- 增加`make icache-calibrate-penalty`，在同一个RV32 ysyxSoC、SDRAM、AXI delay和原生
  BL8环境中依次构建16/32/64B I-cache并运行MicroBench；
- 每完成一种line大小就把PMU统计写入CSV，并单独保存完整仿真日志，避免长时间校准中途
  停止时丢失已经完成的结果；
- 增加`make cachesim-explore-calibrated`。cachesim从CSV按line大小分别读取critical
  miss penalty和complete refill latency，不再为所有候选配置套用同一个周期常数；
- 增加校准输出解析、CSV读取和参数检查单元测试。

MicroBench `test`流程验证结果：

| Line | Miss | Critical penalty | Complete refill | PMU周期 | PMU退休指令 | PMU IPC | 精确AMAT |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 16B | 1301 | 32.061 | 80.953 | 2304079 | 430203 | 0.186714 | 2.039641 |
| 32B | 689 | 31.106 | 48.536 | 2268195 | 430203 | 0.189668 | 2.020366 |
| 64B | 368 | 39.745 | 89.378 | 2267304 | 430203 | 0.189742 | 2.013898 |

相对32B，16B测量窗口多35884周期（+1.582%），64B少891周期（-0.039%）。64B的单次
关键字和整行代价都高于32B，但miss次数减少使AMAT和总周期略低；该`test`结果只验证流程并
给出趋势，正式参数选择仍需`train`校准和代表性PC trace。当前默认bubble-sort trace只有
6次miss，因此只用于验证cachesim确实读取了三组独立周期，不能据此冻结line大小。

## 2026-08-22 - RV32课程面积基线的RTL结构优化

本轮固定使用Nangate45、`DELAY 0`综合策略和1000MHz约束，不修改ABC策略、库、时序约束
或存储器黑盒。所有面积变化均来自RTL状态与存储结构调整，I-cache tag/data array仍按真实
标准单元参与综合。

主要结构调整：

- I-cache命中流水线删除重复保存的S2请求、tag和data副本，S1请求直接和同步array读结果
  完成比较；direct-mapped配置不再保存没有信息量的替换路索引和逐路失效计数器；
- miss unit只保存尚未完成事务必需的地址、属性和响应数据，set/tag/word index按需由地址
  计算；综合电路不再保存仅供断言检查的整行beat接收位图；
- refill和uncached AXI master不再寄存完整请求/响应bundle，只保存跨周期仍有意义的事务
  上下文；AXI R/B响应遵守VALID保持规则，直接通过ready/valid交给上游；
- LSU删除重复的完整writeback缓冲状态，fetch buffer固定为当前顺序核实际需要的单entry
  弹性寄存器；寄存器堆不再物理实现恒为零的x0，但仍保留完整RV32I的32个体系结构编号；
- RV32课程面积基线将参数化I-cache容量设为32B、line保持16B。RV64顺序核仍默认64B，
  两者实例化同一套参数化RTL，没有保留旧实现或兼容分支。

同一综合命令下的结果：

| 配置 | 总面积 | 时序单元面积 | 最高频率估计 |
| --- | ---: | ---: | ---: |
| 优化后的64B I-cache RV32 | 24733.212 um^2 | 未单独记录 | 623.879 MHz |
| 32B课程面积基线最终RTL | 22088.374 um^2 | 10145.506 um^2 | 562.267 MHz |

相对本轮开始时的29456.042 um^2，最终减少7367.668 um^2，即25.0%，并低于手册建议的
23000 um^2面积线。当前562.267MHz不是目标频率结果：uncached R/B直通减少了响应寄存器，
但形成了AXI响应到LSU格式化、completion再到GPR写回的长组合路径。用户当前优先要求面积，
因此暂不通过增加流水寄存器换取频率；进入流水线阶段时应重新切分该路径。

验证结果：

- `make lint-npc NPC_CONFIG=rv32-baseline`和`rv64-sequential`均通过；
- RV32/RV64 uncached AXI定向测试均通过，测试端会在ready为0时保持RVALID/BVALID和payload；
- RV32 LSU定向测试通过；
- 32B默认配置运行`dummy-riscv32-npc.bin`命中good trap，退休13条指令、运行55周期。

32B容量不是最终AI处理器的性能配置。既有NEMU MicroBench test trace中，16B line、
direct-mapped配置从64B降为32B后，miss由64619增加到95540，命中率从91.1153%降到
86.8639%，估算AMAT从2.4022升到2.5929周期。该配置只用于完成课程面积约束并建立可复现
基线；后续应在SRAM宏、流水化命中路径和目标AI workload约束下重新扩大容量和路数。

## 2026-08-22 - RV32课程配置的面积与真实RTL性能联合优化

前一条记录中的32B/16B配置只证明面积可以达标，没有同时满足性能目标。本轮保持外部
lookup、refill和AXI4协议不变，以同一套参数化RTL比较64B容量、direct-mapped下的line大小，
并使用真实ysyxSoC MicroBench统计替代只计算critical miss penalty的简化模型。

定位到的主要问题：

- 当前I-cache只有一个blocking miss表项。critical word可提前返回，但完整line refill结束前
  仍不接受下一次lookup，因此更长line会增加miss期间的前端占用时间；
- 旧AMAT只使用critical response latency，没有计入blocking refill尾部阻塞，因而会高估
  16B line相对8B line的收益；
- 4B line暴露参数化缺陷：word index类型为避免零宽仍保留1 bit，miss unit却曾把PC[2]
  当成line内索引。修复后，单word line的critical word index静态固定为0；
- 单word refill的完整性已经由“最后一个beat同时写data”证明，接收位图断言只在多word
  line中启用，避免把无额外信息的验证状态用于单word配置。

同一Nangate45、300MHz约束和`DELAY 0`策略下：

| 容量/路数/line | 总面积 | 300MHz WNS | 最高频率估计 | 结论 |
| --- | ---: | ---: | ---: | --- |
| 64B/1-way/4B | 23988.146 um^2 | +0.653 ns | 373.182 MHz | 超过23000 um^2，淘汰 |
| 64B/1-way/8B | 22708.952 um^2 | +0.578 ns | 363.022 MHz | 满足面积约束，选为课程默认 |

真实ysyxSoC MicroBench `test`对比：

| 配置 | Total | 全程CPU周期 | I-cache hit rate | miss critical | complete refill |
| --- | ---: | ---: | ---: | ---: | ---: |
| 32B/1-way/16B旧面积基线 | 约1033 ms | 约107M | 未记录 | 未记录 | 未记录 |
| 64B/1-way/16B | 753.748 ms | 78659855 | 85.146% | 237.170 cycles | 565.662 cycles |
| 64B/1-way/8B | 563.649 ms | 58905189 | 78.922% | 163.405 cycles | 286.283 cycles |

8B line相对16B line的命中率更低，但完整refill占用约减半，总周期减少19754666，
MicroBench Total减少25.2%。相对旧32B/16B面积基线，Total约减少45.4%，同时总面积仍低于
23000 um^2。4B line修复后通过standalone dummy，但13次取指全部miss、运行78周期；相比
8B line的54周期已经显示其空间局部性不足，再加上面积超限，因此不再运行耗时的完整
MicroBench作为参数选择依据。

最终RV32课程默认配置冻结为64B容量、direct-mapped、8B line。它不是长期AI处理器的最终
I-cache：流水线阶段应通过多MSHR、hit-under-miss、refill/lookup端口仲裁或banking解除
blocking tail，而不是继续依赖缩短line。长期配置仍需在SRAM宏和目标AI workload下重新探索。

## 2026-08-22 - MicroBench train紧凑trace与blocking TMT探索

为避免每组RTL参数都运行数小时级MicroBench `train`，本轮在NEMU中加入二进制紧凑PC
trace。每条记录保存起始PC、连续指令数和固定步长，`cachesim`可直接重放，也继续兼容旧的
文本trace。MicroBench `train`在NEMU中通过全部测试，共执行63102503条指令，生成118MiB
trace；该结果用于第一阶段几何筛选，不能替代最终RTL回归。

同一条train trace、64B容量、direct-mapped下：

| line | Miss | Hit Rate |
| ---: | ---: | ---: |
| 4B | 28180869 | 55.3411% |
| 8B | 15977866 | 74.6795% |
| 16B | 9246162 | 85.3474% |
| 32B | 8105770 | 87.1546% |
| 64B | 9708149 | 84.6153% |

容量扩展对miss更有效：1KiB/8B/1-way为667497次，2KiB/8B/2-way为386012次，
8KiB/8B/4-way为2461次。但当前标准单元array下，128B/16B核面积已达到
25406.458 um^2，无法满足23000 um^2课程约束。

当前单MSHR I-cache在整行安装完成前不接收下一次lookup，因此新增`blocking TMT`：miss次数
乘以完整refill延迟。PSRAM标定下，8B、16B、32B line的完整refill分别为286.283、
565.662、1121.856周期；对应train blocking TMT为4.574e9、5.230e9、9.094e9周期。
16B只看critical TMT时优于8B，但blocking TMT高14.3%；32B将miss减少49.3%，完整refill
延迟却增加到约3.92倍，最终阻塞时间约翻倍。

补充综合与RTL `test`证据：

| 配置 | 核面积 | Fmax估计 | MicroBench Total | 全程CPU周期 | Hit Rate |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64B/1-way/4B | 23988.146 um^2 | 373.182 MHz | 未运行 | 未运行 | train 55.3411% |
| 64B/1-way/8B | 22708.952 um^2 | 363.022 MHz | 563.649 ms | 58905189 | 78.922% |
| 64B/1-way/16B | 22474.340 um^2 | 389.599 MHz | 753.748 ms | 78659855 | 85.146% |
| 64B/1-way/32B | 21808.276 um^2 | 403.614 MHz | 1304.315 ms | 134882469 | 86.446% |

因此保持64B/1-way/8B为课程默认。它是在标准单元面积约束和当前blocking微架构下的局部
最优点，不是长期AI CPU的最终配置。

## 2026-08-22 - AXI SDRAM短burst连续读优化

此前正式`make perf`默认使用`riscv32-ysyxsoc-psram`，实际路径为AXI到APB桥、APB延迟器和
PSRAM，无法验证B4要求的AXI SDRAM burst。现将性能和I-cache缺失代价标定默认环境统一为
`riscv32-ysyxsoc-sdram`，PSRAM仅保留为启动和外设验证环境。

RTL检查发现I-cache refill master已经发送完整AXI4 INCR burst，但SDRAM边界只在32-bit、
32B对齐且至少8 beat时使用连续读分段器。RV32课程默认8B line只产生2 beat，因此仍被拆成
两条独立SDRAM READ。改造后，所有多beat、32-bit、word对齐的INCR事务均进入分段器；每个
物理段的beat数取事务剩余beat、到下一个32B边界的beat和8三者最小值。SDRAM core接受
`len=0..7`表示1..8 beat，短段在最后一个所需beat后发送BURST TERMINATE，完整BL8自然结束。

定向测试覆盖2、4、8、16 beat以及跨32B边界的4/16 beat事务：

| AXI事务 | 物理分段 | SDRAM READ数 | BURST TERMINATE数 |
| --- | --- | ---: | ---: |
| 对齐2 beat | 2 | 1 | 1 |
| 对齐4 beat | 4 | 1 | 1 |
| 对齐8 beat | 8 | 1 | 0 |
| 对齐16 beat | 8 + 8 | 2 | 0 |
| 偏移1 word的16 beat | 7 + 8 + 1 | 3 | 2 |
| 偏移6 word的4 beat | 2 + 2 | 2 | 2 |

在RV32、64B容量、direct-mapped、8B line、MicroBench `test`下，仅切换SDRAM传输实现：

| 指标 | 独立BL1 | 连续读 | 变化 |
| --- | ---: | ---: | ---: |
| Scored time | 72.120 ms | 52.010 ms | -27.884% |
| Total time | 96.100 ms | 71.005 ms | -26.113% |
| PMU窗口周期 | 7191928 | 5187565 | -27.870% |
| PMU窗口IPC | 0.059817 | 0.082929 | +38.638% |
| 全程CPU周期 | 10086928 | 7479025 | -25.854% |
| miss critical response | 27.176 cycles | 25.559 cycles | -5.950% |
| complete refill | 41.473 cycles | 26.216 cycles | -36.788% |
| I-cache AMAT | 6.521 cycles | 6.176 cycles | -5.291% |
| lookup等待周期 | 2665027 | 304324 | -88.581% |

关键字到达只提前约1.6周期，因此AMAT改善有限；主要收益来自第二个word不再重新支付地址、
SDRAM命令和首数据延迟，使blocking miss更早释放，显著减少下一次lookup等待。两组PMU测量
窗口均退休430203条指令且MicroBench全部通过，比较口径一致。该结果证明当前8B line也实际
使用了AXI burst和SDRAM连续数据阶段，不再只是接口上携带`ARLEN`。

## 2026-08-22 - 64B与1KiB I-cache瓶颈分离实验

为判断低IPC来自AXI/SDRAM实现还是课程面积版I-cache容量，在相同RV32核、8B line、
direct-mapped、AXI SDRAM连续读和MicroBench `test`下，只把I-cache容量从64B改为1KiB：

| 指标 | 64B | 1KiB | 变化 |
| --- | ---: | ---: | ---: |
| Scored time | 52.010 ms | 18.310 ms | -64.795% |
| Total time | 71.005 ms | 29.714 ms | -58.152% |
| PMU窗口周期 | 5187565 | 1818657 | -64.942% |
| PMU窗口IPC | 0.082929 | 0.236549 | +185.243% |
| I-cache hit rate | 78.923% | 98.567% | +19.644 pp |
| I-cache AMAT | 6.176 cycles | 1.371 cycles | -77.801% |
| miss次数 | 172752 | 11927 | -93.096% |
| IFU平均响应延迟 | 7.753 cycles | 2.924 cycles | -62.286% |

两组PMU窗口都退休430203条指令。1KiB配置证明64B课程面积版的容量缺失是`0.08` IPC的首要
原因，而不是AXI burst失效。扩大容量后IFU downstream backpressure升至39.347%，表示前端
已经频繁早于顺序后端准备好指令；此后继续扩大I-cache的边际收益有限。剩余主要开销来自
顺序核同一时刻只允许一个lookup在途、每条指令等待完成后才推进，以及无D-cache LSU的
长延迟访问。1KiB配置只用于瓶颈分离，不替代满足23000um^2约束的64B课程面积配置。

## 2026-08-22 - 1KiB默认配置与自修改代码一致性回归

根据前一轮瓶颈分离结果，RV32I开发默认配置正式调整为1KiB容量、direct-mapped、8B line；
RV64顺序配置继续保持64B/16B，RV32仍为RV32I而非RV32E。该决定优先减少容量miss和仿真
时间，小面积64B配置仍可通过命令行参数复现实验，但不再作为默认性能配置。

新增两项SDRAM自修改代码测试。两项测试都先执行一次返回1的目标函数，使对应line进入
I-cache，再用store把第一条指令改成返回2：

| 测试 | 同步操作 | 第二次调用结果 | 结论 |
| --- | --- | ---: | --- |
| `icache-smc-no-fence` | 仅编译器memory barrier | 1 | store更新了SDRAM，但旧I-cache line仍可见 |
| `icache-smc-fence-i` | `fence.i` | 2 | I-cache metadata失效后重新从SDRAM取到新指令 |

执行命令：

```sh
cd /home/yong/ysyx/ysyx-workbench/am-kernels/tests/cpu-tests
make ARCH=riscv32-ysyxsoc-sdram ALL=icache-smc-no-fence run
make ARCH=riscv32-ysyxsoc-sdram ALL=icache-smc-fence-i run
```

两项均命中good trap。无`fence.i`测试用于复现当前微架构的旧副本，不是通用ISA符合性
断言；有`fence.i`测试才是必须满足的架构结果。

## 2026-08-22 - D-cache设计空间与流水线理想收益

NEMU新增紧凑架构数据访问trace，cachesim扩展为write-back、write-allocate、精确LRU的
D-cache模型，并单独统计dirty eviction、writeback流量和写回占用。MicroBench `test`共产生
98857条普通内存访问；1KiB、2-way、32B line得到95.7019%命中率、4249次miss和3290次
脏块替换。归一化blocking TMT为79639周期，其中32900周期来自脏块写回，占41.3%。这证明
只使用命中率或refill次数会高估D-cache收益。

72组参数扫描中，8KiB、64B、4-way的归一化blocking TMT最低，为43468周期，较1KiB、
32B、2-way减少45.4%。该结果只用于几何参数排序；正式RTL仍需使用真实SDRAM写延迟、综合
面积和目标AI workload复核。

在RV32、1KiB/1-way/8B I-cache、MicroBench `test`下，完整仿真为3284092 active cycles、
832171条退休指令。仿真计数器给出的理想上限为：

| 假设 | 估算周期 | 估算IPC | 相对当前加速比 |
| --- | ---: | ---: | ---: |
| 当前RTL | 3284092 | 0.253395 | 1.000x |
| 神谕单周期数据存储器 | 1967326 | 0.422996 | 1.669x |
| 理想单发射流水线 | 2457466 | 0.338630 | 1.336x |
| 理想流水线和神谕数据存储器 | 1140700 | 0.729527 | 2.879x |

神谕数据存储器删除每条load/store超过基础一周期的执行开销，它不是具体D-cache模型；理想
单发射流水线保留当前数据访存额外开销和I-cache miss额外开销，其余按每条退休指令一个基础
周期计算。二者是同一基线上的反事实上限，不能直接相乘。手册关于D-cache性价比较低的结论
来自有限面积下可实现D-cache的实际命中率、miss和写回成本，不能用神谕上限替代。基于收益
与面积证据，下一步先实现顺序流水线；正式D-cache延后到可使用SRAM宏的配置。

## 2026-08-24 - RV32 I-cache默认切换为2-way

在当前RTL、Nangate45、300MHz约束下，固定I-cache为64B容量和8B line，只改变相联度：

| 配置 | 纯core面积 | 时序单元面积 | STA估算频率 |
| --- | ---: | ---: | ---: |
| 1-way | 22708.952 um^2 | 5019.154 um^2 | 363.022 MHz |
| 2-way | 22522.220 um^2 | 5362.826 um^2 | 343.869 MHz |
| 变化 | -186.732 um^2 (-0.822%) | +343.672 um^2 | -5.276% |

2-way增加第二路tag比较、命中数据选择和替换状态，但将set数量从8减为4。在当前极小、由
标准单元实现的array中，较浅阵列减少的组合选择逻辑超过新增逻辑，因此总面积没有增加；
时序单元面积和命中路径延迟仍然上升。该结果只证明当前课程面积配置可以使用2-way，不能
代替未来SRAM宏配置的面积和时序评估。

默认构建配置由`1KiB/1-way/8B line`切换为`1KiB/2-way/8B line`。课程面积结果可用
`NPC_ICACHE_CAPACITY_BYTES=64 NPC_ICACHE_WAY_COUNT=2 NPC_ICACHE_LINE_BYTES=8`复现。

## 2026-08-24 - 首版顺序流水线功能基线

在不改变I-cache、LSU、CSR、commit和DiffTest语义契约的前提下，增加ID/EX与
completion/WB两个弹性流水寄存器。冒险控制首版使用无forwarding RAW停顿、blocking LSU
结构停顿和串行化排空；EX级控制转移清除年轻ID/EX内容，commit级trap、`mret`和`fence.i`
同时阻止年轻completion进入WB。IFU继续使用epoch丢弃已发出但属于旧控制流的取指响应。

验证结果：

| 验证项 | 结果 |
| --- | --- |
| `make test-pipeline-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make test-lsu-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make lint-configs PROJECT=riscv32` | RV32/RV64通过，仅保留既有未使用字段警告 |
| `make regression-p3-f-rv32 PROJECT=riscv32` | 35/35通过 |
| `make regression-p3-f-rv64 PROJECT=riscv32` | 35/35通过 |
| `make perf PERF_SCALE=test PROJECT=riscv32 NPC_CONFIG=rv32-baseline` | MicroBench PASS |

MicroBench `test`的PMU窗口和整机计数如下：

| 指标 | 数值 |
| --- | ---: |
| PMU窗口退休指令 | 430203 |
| PMU窗口周期 | 2157726 |
| PMU窗口IPC | 0.199377 |
| 整机退休指令 | 832832 |
| 整机active周期 | 3907196 |
| 整机IPC | 0.213153 |
| RAW等待周期 | 210273（5.382%） |
| 串行化等待周期 | 33（0.001%） |
| LSU结构等待周期 | 1429031（36.574%） |
| 控制flush | 177775次 |
| I-cache命中率 | 99.109% |
| I-cache AMAT | 1.228周期 |

首版流水线的IPC低于此前多周期基线并不表示流水寄存器无效：当前为保证正确性，尚未实现
forwarding和分支预测，并且blocking LSU在整个事务期间阻止年轻指令执行。计数表明首要
限制是LSU结构等待，其次是taken控制流冲刷和RAW等待。该版本用于建立可回归的正确性基线；
后续必须逐项实现forwarding、控制流预测和数据供给优化，并使用同一测试口径比较。

调试期间还修复了架构寄存器堆写入时序：原实现把commit写请求再延迟半个周期，导致流水化
后DiffTest在commit事件上观察到旧GPR值。寄存器堆现改为在commit上升沿直接写入，架构事件
与DiffTest观察点重新一致。

## 2026-08-24 - IFU同周期请求换手

首版IFU在每个lookup响应结束后都返回发送状态，即使I-cache已经空闲，也要等到下一周期才
呈现顺序请求。该结构正确但固定引入一周期前端空泡。修改后，当前响应交付给IDU的同一周期
直接呈现下一顺序PC；I-cache接收时继续等待新响应，I-cache反压时转入发送状态并保持同一
请求。redirect同拍出现时禁止顺序旁路，由redirect目标和新epoch重新启动取指。

没有增加fetch queue、MSHR、宽payload寄存器或同时在途事务数。性能监视器同步支持“旧响应
完成与新请求开始同拍”的记账，并把反压期间持续为1的response valid只统计一次。

验证结果：

| 验证项 | 结果 |
| --- | --- |
| `make test-pipeline-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make lint-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make regression-p3-f-rv32 PROJECT=riscv32` | 35/35通过 |
| `make regression-p3-f-rv64 PROJECT=riscv32` | 35/35通过 |
| `make perf PROJECT=riscv32 NPC_CONFIG=rv32-baseline PERF_SCALE=test` | MicroBench PASS |

同一MicroBench PMU测量窗口对比：

| 指标 | 串行IFU | 同周期换手 | 变化 |
| --- | ---: | ---: | ---: |
| 退休指令 | 430203 | 430203 | 0 |
| 周期 | 2157726 | 1971267 | -186459（-8.64%） |
| IPC | 0.199377 | 0.218236 | +9.46% |

新版本完整运行的active周期为3549239，退休832809条指令，IPC为0.234644。I-cache命中率
99.109%，AMAT为1.229周期，说明前端固定请求空泡已删除；剩余主要限制为711592个RAW等待
周期、1426390个LSU结构等待周期、177815次控制flush，以及占active周期59.314%的IFU下游
反压。下一阶段优先实现数据forwarding、缩短blocking LSU占用并加入控制流预测。

为隔离本次优化的硬件成本，使用同一份流水线RTL，只把IFU恢复为响应后下一拍再发请求，
并在RV32、64B/2-way/8B line、Nangate45、300MHz约束下做A/B综合：

| 指标 | 严格串行IFU | 同周期换手 | 变化 |
| --- | ---: | ---: | ---: |
| 纯core面积 | 25372.676 um^2 | 25627.770 um^2 | +255.094 um^2（+1.01%） |
| 时序单元面积 | 11747.890 um^2 | 11747.890 um^2 | 0 |
| STA估算关键路径频率 | 525.888 MHz | 596.652 MHz | 两者均满足300MHz |

频率差异包含综合映射启发式影响，不能据此断言旁路本身提升了后端频率；可以确认的是新增
组合路径没有成为当前关键路径。当前完整流水线core面积为25627.770 um^2，比课程25000
um^2上限高2.51%，后续面积优化必须以当前功能和同一综合约束为基线，不能删除架构语义或
改变模块协议来获得表面数字。

## 2026-08-24 - 顺序流水线精确同步异常

异常字段继续随指令payload逐级传递，只有commit可以产生trap和更新CSR。补充EBREAK异常，
修复IFU access fault可能被IDU按返回位型覆盖，以及上游异常经过LSU时仍保留`writes_rd`的
问题。EXU、LSU和commit增加无副作用断言，core增加“异常提交必须阻止EX发射并冲刷ID/EX、
WB”的恢复断言。

新增定向测试构造三条不同年龄的异常指令：最老load access fault位于WB，年轻illegal
instruction位于ID/EX，最年轻instruction access fault位于译码输入。验证只有WB异常的PC、
cause和tval进入commit，年轻异常没有被接受，并在提交redirect后全部清空。

| 验证项 | 结果 |
| --- | --- |
| `make test-idu-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make test-exu-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make test-lsu-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make test-pipeline-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make test-privileged-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make regression-p3-f-rv32 PROJECT=riscv32` | 35/35 DiffTest通过 |
| `make regression-p3-f-rv64 PROJECT=riscv32` | 35/35 DiffTest通过 |

当前没有MMU和U/S-mode，因此页故障以及U/S-mode ECALL仅保留cause编码，不会由RTL产生；
中断仲裁也不属于本次同步异常改动。

AM使用提交的`EBREAK`作为宿主仿真终止标记，而RTL仍按架构把该指令标记为断点异常。DPI回调
在提交沿设置仿真结束状态，因此C++执行循环必须先检查结束状态，再决定是否让NEMU继续执行
终止标记。这样既保留硬件断点异常语义，又避免把宿主退出约定之后的PC重定向拿去做一次
没有意义的DiffTest比较。

## 2026-08-24 - Fetch queue、操作数前递与流水线控制BMC

在IFU和IDU之间增加两项寄存器化fetch queue。I-cache本地命中、lookup端口ready、无redirect
且队列有空间时，IFU可以连续每拍交付一条指令；IDU短暂停顿先消耗队列容量，队列满后才向
IFU传播反压。redirect禁止当拍旧路径入队，并在时钟沿清空已经缓冲的旧路径指令。

hazard controller增加EX和WB两个前递来源。EX是更新的生产者，优先于WB；若EX命中源寄存器
但结果尚不可用，则必须保持RAW停顿，不能退回使用更旧WB结果。普通ALU依赖可从EX直接前递，
同拍提交的结果可从WB前递；load-use在LSU完成前仍停顿。

验证结果：

| 验证项 | 结果 |
| --- | --- |
| `make lint-configs PROJECT=riscv32` | RV32/RV64通过，仅保留既有未使用字段警告 |
| `make test-pipeline-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make formal-pipeline` | BMC深度20通过 |
| `make regression-p3-f-rv32 PROJECT=riscv32` | 35/35 DiffTest通过 |
| `make regression-p3-f-rv64 PROJECT=riscv32` | 35/35 DiffTest通过 |
| `make perf PROJECT=riscv32 NPC_CONFIG=rv32-baseline PERF_SCALE=test` | MicroBench PASS |

MicroBench同一PMU测量窗口对比：

| 指标 | 同周期IFU换手 | Fetch queue和前递 | 变化 |
| --- | ---: | ---: | ---: |
| 退休指令 | 430203 | 430203 | 0 |
| 周期 | 1971267 | 1770976 | -200291（-10.16%） |
| IPC | 0.218236 | 0.242918 | +11.31% |

新版本完整运行的active周期为3284725，退休834484条指令，IPC为0.254050。主要计数为：

| 指标 | 数值 |
| --- | ---: |
| RAW等待周期 | 255742（7.786%） |
| LSU结构等待周期 | 1438484（43.793%） |
| 控制flush | 178314次 |
| IFU下游反压周期 | 1650655（50.252%） |
| I-cache命中率 | 99.186% |
| I-cache AMAT | 1.219周期 |

这组计数不能解释为IFU命中吞吐不足。队列能吸收短时反压，但blocking LSU会让IDU持续多拍
不接收，任何有限队列最终都会填满。当前性能优化优先级应为：缩短或解耦LSU占用、解决
load-use等待、加入分支预测，最后再根据前端并发需求增加lookup在途数。

形式验证采用独立顺序参考模型检查fetch queue的顺序、容量、flush和反压性质，并检查前递
选择的最新生产者优先规则。它没有把当前整核与旧单周期核做提交事件等价，因此不能声称已经
完成手册所述的整核形式化验证；整核版本还需要固定单周期REF，并比较每条退休指令的PC、
next PC、GPR写入、CSR写入和trap事件。

## 2026-08-25 - 流水线瓶颈归因、控制流预测和uncached请求首拍直通

所有性能数据使用同一RV32、1KiB/2-way/8B line I-cache、MicroBench `test`和仿真延迟配置。
先把每拍发射槽按互斥优先级分类，避免把能同时发生的IFU通道占用、LSU busy和RAW等待重复
相加。结果确认I-cache命中路径可每拍接受一次lookup，命中延迟为1拍；主要瓶颈是blocking
LSU，其次是控制流恢复和真正的前端空供给。

控制流A/B：

| 配置 | PMU周期 | PMU IPC | Scored time | EX纠错redirect |
| --- | ---: | ---: | ---: | ---: |
| Fetch queue和forwarding | 1770976 | 0.242918 | 17.829 ms | 未单独记录 |
| 静态BTFNT和`jal` | 1689290 | 0.254664 | 17.016 ms | 85618 |
| 16项BHT和`jal` | 1593126 | 0.270037 | 16.053 ms | 50004 |
| 16项BHT、`jal`和AXI首拍直通 | 1513766 | 0.284193 | 15.261 ms | 50028 |

16项BHT只使用32位两位饱和计数器。64项模型在同一运行中只比16项少1306次条件分支错误，
不足以证明新增96位状态和更宽索引逻辑值得实现。预测器不预测`jalr`，所以剩余50028次错误
中有15506次来自间接跳转。加入BTB或RAS前应先用同一工作负载做独立收益模型。

初版把32位动态预测target随fetch queue和流水payload传递，64B课程配置面积为
28322.616 um^2。当前预测范围只有PC相对branch和`jal`，因此改为只保存taken位、在EX重建
预测next PC，面积降至27375.656 um^2，功能和性能完全不变，节省946.960 um^2。

uncached AXI master原来在idle接收本地请求，下一拍才驱动AR或AW/W，给每次load/store增加
固定一拍。修改后idle首拍直接驱动AXI；若握手成功直接进入响应状态，否则保存请求上下文并
进入原有发送状态。仍然只允许一个在途事务，未改变AXI通道独立握手、响应顺序或精确异常
边界。相对加入BHT后的版本：

| 指标 | 修改前 | 修改后 | 变化 |
| --- | ---: | ---: | ---: |
| Scored time | 16.053 ms | 15.261 ms | -4.93% |
| PMU IPC | 0.270037 | 0.284193 | +5.24% |
| load平均延迟 | 13.622 cycles | 12.341 cycles | -1.281 cycles |
| store平均延迟 | 7.880 cycles | 6.799 cycles | -1.081 cycles |
| LSU结构阻塞 | 1449100 cycles | 1311534 cycles | -137566 cycles |
| 64B课程配置面积 | 27375.656 um^2 | 27541.640 um^2 | +165.984 um^2 |

最终完整运行active周期为2735624，退休844963条指令，IPC为0.308874。互斥发射槽归因：

| 类别 | 周期 | 占active比例 |
| --- | ---: | ---: |
| 已发射指令 | 844964 | 30.887% |
| LSU结构阻塞 | 1311534 | 47.943% |
| 控制恢复 | 247113 | 9.033% |
| 前端供给 | 265602 | 9.709% |
| 未解决RAW | 39397 | 1.440% |
| 串行化和其他 | 27014 | 0.987% |

I-cache为99.062% hit、1拍hit latency、28.662拍critical miss latency和1.260拍AMAT。
因此当前不增加I-cache命中流水级：它不会改善每拍一条的命中吞吐，而且综合关键路径已转到
预测redirect/IFU PC和AXI输出边界。后续首要工作是D-cache、store buffer和有序访存完成；
不能在没有load queue、scoreboard或ROB时让年轻指令直接越过blocking LSU。

验证结果：RV32 35/35 DiffTest通过；流水线BMC深度20通过；uncached AXI RV32/RV64定向测试
通过。64B课程配置在300MHz约束下TNS为0，综合面积27541.640 um^2，最紧core输出路径报告
频率431.896MHz。

## 2026-08-25 - 首版D-cache与I/D共享内存仲裁

加入默认1 KiB、2-way、32 B line的write-back/write-allocate阻塞式D-cache。LSU接口保持
`data_memory_req_t`，PMA在D-cache、uncached和本地access fault之间选择；D-cache内部使用
同步tag/data array、invalid-way优先加每set round-robin替换、单MSHR miss unit和AXI burst
refill/writeback adapter。`fence.i`维护顺序改为先clean D-cache，再invalidate I-cache。

共享内存端口继续由`riscv32_axi4_core_merge`统一处理。新增断言和定向测试，验证AR反压期间
请求来源/payload稳定、AR握手后来源锁定到`RLAST`、R响应只到达一个上游，以及连续竞争时
round-robin不会固定饿死数据侧。

验证结果：

| 验证项 | 结果 |
| --- | --- |
| `make test-dcache-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make test-core-merge-configs PROJECT=riscv32` | RV32/RV64通过 |
| `make lint-npc PROJECT=riscv32 NPC_CONFIG=rv64-sequential` | 无错误，保留既有unused警告 |
| RV32 standalone `dummy` | `HIT GOOD TRAP`，PC=`0x80000034` |
| RV64 standalone `dummy` | `HIT GOOD TRAP`，PC=`0x8000002c` |

本次只确认功能和协议闭环。D-cache接入后的MicroBench、面积与STA尚未重新运行，因此接入前
0.284193 IPC、27541.640 um^2等数字不能用于评价本版本。当前单MSHR和完整line返回后才恢复
LSU仍是阻塞式检查点；面向AI目标的store buffer、writeback queue、hit-under-miss、多MSHR、
banked array和按ID多在途互联尚未实现。

## 2026-08-25 - Branchsim首轮分支预测探索

- Commit：`uncommitted`
- 架构决策：`D008`
- 工作负载和规模：MicroBench / `test`
- 构建配置：RV32 NEMU退休控制流trace
- 命令：`make branchsim-trace BRANCH_TRACE_SCALE=test && make branchsim-explore`
- 功能结果：MicroBench通过，Branchsim定向测试通过

| 指标 | 当前16项bimodal+JAL | gshare256/history4+BTB32+RAS8 |
| --- | ---: | ---: |
| 退休指令 | 727206 | 727206 |
| 控制流指令 | 193720 | 193720 |
| 预测错误 | 16077 | 9705 |
| MPKI | 22.108 | 13.346 |
| 5级单发射理想IPC | 0.9577 | 0.9740 |
| 预测状态存储估算 | 32 bit | 2568 bit |

当前11125条JALR在无目标预测时全部出错，是首要控制流缺口。RAS8减少约3727次返回错误；
BTB32+RAS8将JALR目标错误降至5632次。BTB继续扩大到64/128项没有收益，256项只减少1次，
因此不应继续用容量换取无效状态。gshare256/history4把条件分支方向错误从4952降至4073。

结果文件：`result/branch/branchsim_riscv32_test_exploration.csv`。本trace包含启动和测试框架，
且Branchsim不模拟错误路径污染、预测训练时序和真实存储阻塞；最终RTL决策仍需train、AI
runtime代表性trace、RTL PMU、综合和STA共同确认。

## 2026-08-25 - D-cache性能与标准单元面积检查

- Commit：`uncommitted`
- 架构决策：`D006`、`D007`、`D009`
- 工作负载和规模：MicroBench / `test`
- 构建配置：RV32、1 KiB/2-way/8 B line I-cache、1 KiB/2-way/32 B line D-cache
- 性能命令：`make perf PROJECT=riscv32 NPC_CONFIG=rv32-baseline PERF_SCALE=test`
- 综合命令：`make sta PROJECT=riscv32 NPC_CONFIG=rv32-baseline STA_OUTPUT_ROOT=/home/yong/ysyx/ysyx-workbench/npc/result/sta/NanGate45-rv32-baseline-icache-1024b-way-2-line-8b-dcache-1024b-way-2-line-32b`
- 功能结果：MicroBench全部通过，`HIT GOOD TRAP`
- 综合结果：NanGate45、300 MHz；WNS=+0.173 ns，TNS=0，面积=156409.064 um^2

| 指标 | 接入D-cache前 | 当前D-cache | 变化 |
| --- | ---: | ---: | ---: |
| PMU退休指令 | 430203 | 430203 | 0 |
| PMU周期 | 1513766 | 867290 | -42.71% |
| PMU IPC | 0.284193 | 0.496031 | +74.54% |
| Scored time | 15.261 ms | 8.784 ms | -42.44% |
| load平均延迟 | 12.341 cycles | 3.652 cycles | -8.689 cycles |
| store平均延迟 | 6.799 cycles | 7.948 cycles | +1.149 cycles |

当前完整运行active周期为2141585，退休844557条指令，IPC为0.394361。发射槽归因中，
LSU结构阻塞仍占34.309%，控制恢复占11.539%，前端供给占12.343%。D-cache明显缓解了
memory wall，但阻塞式单MSHR、store完成路径和共享内存端口仍限制吞吐。

面积结论不能通过接入前27541.640 um^2直接计算D-cache增量，因为该旧综合使用64 B
I-cache，而当前综合使用1 KiB I-cache。当前可确认的结论只有：这套1 KiB I/D cache标准
单元实现达到课程25000 um^2上限的6.26倍，不能用于课程面积签核。下一项实验必须在同一
commit上建立可关闭D-cache的命名配置，并对小容量I-cache、无D-cache基线以及低成本数据
缓冲候选方案进行严格A/B。

## 2026-08-25 - 关闭D-cache的课程面积受控基线

- Commit：`uncommitted`
- 架构决策：`D009`
- 工作负载和规模：MicroBench / `test`
- 构建配置：`rv32-course-area`，64 B/2-way/8 B line I-cache，D-cache关闭
- 性能命令：`make perf PROJECT=riscv32 NPC_CONFIG=rv32-course-area PERF_SCALE=test`
- 综合命令：`make sta PROJECT=riscv32 NPC_CONFIG=rv32-course-area`
- 功能结果：MicroBench全部通过，`HIT GOOD TRAP`
- 综合结果：NanGate45、300 MHz；WNS=+0.810 ns，TNS=0，面积=27541.108 um^2，
  估算Fmax=396.417 MHz

| 指标 | 结果 |
| --- | ---: |
| PMU退休指令 | 430203 |
| PMU周期 | 5295945 |
| PMU IPC | 0.081232 |
| Scored time | 53.093 ms |
| 前端供给停顿 | 54.403% |
| LSU结构停顿 | 18.385% |
| 控制恢复停顿 | 10.845% |
| I-cache命中率 | 79.204% |
| I-cache AMAT | 6.812 cycles |
| 理想消除数据访存延迟的加速上限 | 1.230x |

该配置关闭D-cache后仍超过25000 um^2上限2541.108 um^2，即10.16%。2320个DFF_X1占约
10486.4 um^2，512个DLH_X1占1361.92 um^2；后者对应64 B I-cache数据存储。性能上，
极小I-cache造成的前端停顿已经远高于数据侧停顿，因此下一轮不能先加入D-cache。项目保持
标准RV32I，不再通过RV32E寄存器规模换面积；只允许通过流水payload去冗余等结构调整回收
面积，再将回收的面积按“减少周期数/新增面积”投入I-cache、预测器或小型数据缓冲。任何
候选方案都必须重新运行相同MicroBench和STA，不能用不同I-cache容量的历史数字直接相减。

## 2026-08-25 - RV32I缓存面积、IPC与频率联合探索

- Commit：`uncommitted`
- 工作负载：MicroBench / `test`
- 固定条件：RV32I、256 B direct-map/16 B line I-cache、相同AXI延迟模型和NanGate45流程
- 比较指标：测量窗口IPC、STA Fmax、纯core面积和`IPC * Fmax`

| D-cache配置 | IPC | Fmax | 面积 | `IPC * Fmax` |
| --- | ---: | ---: | ---: | ---: |
| 关闭 | 0.221131 | 547.909 MHz | 37175.894 um^2 | 121.15 MIPS |
| 128 B/direct/16 B | 0.271584 | 518.547 MHz | 50174.516 um^2 | 140.82 MIPS |
| 256 B/direct/16 B | 0.303015 | 506.811 MHz | 58899.848 um^2 | 153.57 MIPS |
| 256 B/2-way/16 B | 0.334515 | 498.001 MHz | 59696.784 um^2 | 166.59 MIPS |

选择256 B/2-way D-cache作为`rv32-baseline`。它相对同容量direct-map增加796.936 um^2，
却提高10.4% IPC和8.5%的综合吞吐代理。相反，BHT16扩到BHT64按RTL纠错次数估算的总周期
理想收益不足1%，RAS4扩到RAS8在trace中只减少250次错误，因此两者均不扩容。

最终配置的完整运行互斥停顿为：LSU结构31.757%、前端27.631%、控制恢复8.965%、RAW
1.130%。当前不再存在单一绝对瓶颈。初次STA报告的498.001 MHz关键路径从EX级
`execute_packet`经过LSU请求形成、PMA和当前请求路由选择，一直穿到data AXI输出。进一步
检查协议时序后确认：D-cache和uncached adapter在接收请求的首拍都只锁存请求或启动array
read，不会在这一拍产生有效AXI请求，因此按当前PMA结果选择AXI输出是无收益组合旁路。

删除这条旁路后，MicroBench测量IPC保持0.334515，面积从59696.784 um^2变为
59704.764 um^2，STA频率从498.001 MHz提高到524.833 MHz，`IPC * Fmax`从166.59提高到
175.57 MIPS。新的关键路径从EX/LSU请求形成进入D-cache同步data array读寄存器，数据到达
时间为1.870 ns。无D-cache时约1.788 ns的关键路径则位于I-cache响应、预测、下一PC和下一
lookup的前端反馈路径。

达到1 GHz不能只增加任意流水寄存器。数据侧需要把AGU/LSU请求和cache lookup切成可连续
接收的流水边界，并配合store buffer避免新增级数直接变成每条store的等待；前端需要请求侧
next-line prediction、多个带tag/epoch的在途fetch和选择性squash。两个方向都必须保持
valid-ready协议和每拍请求吞吐，再用IPC、Fmax和面积联合判断，而不能只看流水级数量。

## 2026-08-25 - active-refill word复用与RV32I面积预算校准

- Commit：`uncommitted`
- 工作负载：MicroBench / `test`
- 固定条件：RV32I、direct-map、16 B line、D-cache关闭、相同AXI延迟模型和NanGate45流程
- RTL变化：单MSHR refill进行时，允许读取当前line中已经写入data array的word；不增加
  第二MSHR，不复制cache-line数据，不改变IFU lookup和AXI4 refill协议

64 B配置在优化前后对比：

| 指标 | 优化前 | active-refill复用后 | 变化 |
| --- | ---: | ---: | ---: |
| PMU周期 | 4811915 | 4679472 | -2.75% |
| PMU IPC | 0.089403 | 0.091934 | +2.83% |
| Scored time | 48.230 ms | 46.902 ms | -2.75% |
| 面积 | 28076.832 um^2 | 28068.320 um^2 | -8.512 um^2 |
| Fmax | 532.716 MHz | 536.113 MHz | +0.64% |

相同优化RTL上的容量A/B：

| 容量/路数/line | PMU周期 | IPC | 前端停顿 | I-cache命中率 | 面积 | Fmax | `IPC * Fmax` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 64B/1-way/16B | 4679472 | 0.091934 | 46.872% | 85.999% | 28068.320 um^2 | 536.113 MHz | 49.287 MIPS |
| 128B/1-way/16B | 3692103 | 0.116519 | 41.471% | 90.575% | 31222.282 um^2 | 547.646 MHz | 63.811 MIPS |

128 B增加3153.962 um^2（11.24%），但PMU周期减少21.10%、IPC提升26.74%，综合吞吐代理
提升29.47%，且关键路径仍是`u_ifu.next_fetch_request_pc_q`反馈而不是I-cache容量路径。
因此RV32I工程面积评审线从初始30000调整为32000 um^2，并把128B配置设为当前
`rv32-course-area`默认值。官方RV32E/NanGate45的25000/23000 um^2继续作为原始课程对照，
不与当前RV32I结果混为同一口径。

当前仍有41.471%前端供给停顿和30.611% LSU结构阻塞。下一项前端优化应切断预测/redirect/
next-PC反馈长路径并增加可标识的在途取指，而不是继续无条件增大阻塞式I-cache；数据侧结构
必须另做无D-cache、小缓冲和D-cache候选的同口径A/B。

## 2026-08-26 - 不同set hit-under-miss完整train否决实验

- Commit：`uncommitted`
- 工作负载和规模：MicroBench / `train`
- 固定配置：`rv32-baseline`，256 B/direct/16 B line I-cache，
  256 B/2-way/16 B line D-cache，BHT16、BTB16x2、RAS4
- 性能命令：`make perf PROJECT=riscv32 NPC_CONFIG=rv32-baseline PERF_SCALE=train`
- 综合约束：NanGate45、1000 MHz约束下计算可达频率
- 功能结果：全部子测试通过，`HIT GOOD TRAP`

候选方案在单MSHR refill期间允许不同set进入I-cache lookup；不同set命中直接返回，
不同set miss留在S1等待当前MSHR结束，同set冲突仍阻塞。对照基线与候选使用相同镜像、
cache/predictor参数、AXI延迟模型和综合流程。

| 指标 | 保留基线 | 不同set hit-under-miss | 变化 |
| --- | ---: | ---: | ---: |
| PMU退休指令 | 186810217 | 186810217 | 0 |
| PMU周期 | 492988655 | 492654221 | -0.068% |
| PMU IPC | 0.378934 | 0.379191 | +0.068% |
| Scored time | 4929.979 ms | 4926.640 ms | -0.068% |
| 前端供给停顿 | 28.159% | 27.659% | -0.500个百分点 |
| I-cache命中率 | 97.812% | 97.800% | -0.012个百分点 |
| I-cache AMAT | 1.601 cycles | 1.614 cycles | +0.013 cycles |
| 面积 | 69295.394 um^2 | 69549.424 um^2 | +0.37% |
| Fmax | 797.945 MHz | 767.625 MHz | -3.80% |
| `IPC * Fmax` | 302.368 MIPS | 291.076 MIPS | -3.73% |

候选需要至少减少3.80%的周期才能抵消频率下降，实际只减少0.068%，因此否决并从RTL删除。
完整train还表明，前端停顿的主要组成仍是I-cache miss service（22.429% active cycles），
而不同set hit-under-miss几乎不能缩短它；当前程序在refill期间立即访问其他已缓存set的机会
太少。保留同line已到达word early restart，因为它不增加额外set比较控制路径。

同轮尝试的通用D-cache锁存data array虽然通过定向功能测试，但综合把动态索引和byte strobe
局部写展开为大量process mux，未得到可接受的存储结构，实验在STA完成前终止并撤销。后续
仅评估静态bank或目标SRAM宏实现，不把该写法作为面积优化候选。

## 2026-08-26 - PMA、请求旁路与LSU滚动路径的同口径否决实验

- Commit：`uncommitted`
- 快速性能工作负载：MicroBench / `test`
- 完整性能基线：MicroBench / `train`
- 固定配置：`rv32-baseline`，256 B direct/16 B line I-cache，
  256 B/2-way/16 B line D-cache，BHT16、BTB16x2、RAS4
- STA：NanGate45、1000 MHz约束，报告可达Fmax、纯core面积和TNS

本轮首先固定当前RTL基线。`test`计分窗口退休430203条指令、执行
1194972周期，IPC为0.360010；`train`计分窗口退休186810217条指令、
执行492988655周期，IPC为0.378934，Scored time为4929.979 ms。基线STA为
69448.610 um^2、766.875 MHz、max TNS=-457.502；`test IPC * Fmax`为276.083 MIPS。

| 候选 | `test`周期 | 面积 (um^2) | Fmax (MHz) | max TNS | `IPC * Fmax` (MIPS) | 决策 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 保留基线 | 1194972 | 69448.610 | 766.875 | -457.502 | 276.083 | 保留 |
| PMA通用mask匹配 | 1194972 | 70205.114 | 772.797 | -746.581 | 278.215 | 否决 |
| PMA分层高位解码 | 1194972 | 69548.892 | 752.945 | -785.293 | 271.068 | 否决 |
| PMA展平属性表达式 | 1194972 | 69622.840 | 750.525 | -705.328 | 270.197 | 否决 |
| 数据请求直通+1项skid | 1194972 | 69983.802 | 724.426 | -1500.110 | 260.801 | 否决 |
| 禁用LSU响应拍滚动接收 | 1194972 | 69442.492 | 748.921 | -735.270 | 269.619 | 否决 |

PMA通用mask匹配的Fmax轻微上升，但面积增加1.09%、TNS恶化63.2%，且
`IPC * Fmax`改善只有0.77%，不足以支持在当前小型地址图中引入通用比较网络。
其他两种PMA表达式在逻辑上等价，但映射后均降低Fmax并恶化TNS，因此恢复明确地址区域
优先级的原实现。

数据请求skid候选在空闲时组合直通，目标反压时才保存一个请求。它没有改变周期数，
却把新的pending-valid反馈变成最差路径，Fmax下降5.54%、TNS恶化到-1500.110，
所以已完整删除。这说明弹性缓冲必须把`ready`反馈从存储层级间截断；只在原长路径
上叠加一个“空时旁路”选择器不会自动得到合格的pipeline boundary。

禁用LSU滚动接收后，`test`周期与基线完全相同，说明该负载没有在旧response离开的
同拍提供新LSU请求。但综合映射将最差路径转移到D-cache预读data array输入，Fmax反而
下降2.34%，TNS恶化60.7%；因此恢复LSU滚动接收。最终保留基线并通过顶层lint、
pipeline、LSU和D-cache定向测试。

本轮结论是：RTL源码更短、比较器数量更少或增加一项buffer，都不能直接推导更好的
物理实现。任何优化都必须在相同工作负载、参数和约束下同时检查周期、面积、Fmax、
TNS和关键路径来源。

### 响应侧控制流预译码删除实验

随后测试“只保留请求侧BTB/BHT/RAS、删除I-cache响应侧JAL/branch/ret纠正”的候选。
该候选通过MicroBench `test`，但计分窗口周期从1194972增至1218856（+1.999%），IPC从
0.360010降至0.352956（-1.959%）。删除组合预译码后，面积从69448.610降至
68858.090 um^2（-0.850%），Fmax从766.875升至786.214 MHz（+2.522%），但max TNS从
-457.502恶化到-586.650（恶化28.229%）；`IPC * Fmax`仅从276.083升至277.499 MIPS，
改善0.513%。

该候选只把BTB冷失配推迟到EX恢复，显著增加控制流空泡；频率收益不足以形成稳定的综合
性能优势，且全局负时序总量更差，因此否决并恢复响应侧冷启动纠正。STA最慢路径由LSU
状态反馈转移为IFU `next_fetch_request_pc_q`，说明删除一组逻辑没有消除全局瓶颈，只暴露
了下一组接近的组合反馈路径。下一步不再删除预测能力，而是为预测PC、请求上下文和返回
身份建立清晰的流水寄存/队列边界，在维持每拍请求能力的前提下切断next-PC反馈。

### D-cache请求word提前响应否决实验

随后评估“load miss收到请求word后立即向LSU响应，cache line其余word继续refill”的候选。
该实验同时暴露了一条必须明确的协议边界：向LSU返回架构响应并不等于D-cache的物理事务
已经结束；若refill或writeback仍在进行，数据子系统仍必须为D-cache保留AXI路由所有权，
不能因为LSU已经收到数据就允许下一个请求切换路由。候选版本为此增加了独立的物理事务
存续状态，功能、lint和定向测试均通过。

| 指标 | 保留基线 | 请求word提前响应 | 变化 |
| --- | ---: | ---: | ---: |
| `test` PMU周期 | 1194972 | 1185795 | -0.768% |
| `test` PMU IPC | 0.360010 | 0.362797 | +0.774% |
| 完整运行周期 | 2745651 | 2737266 | -0.305% |
| D-cache平均miss响应 | 57.574 cycles | 53.421 cycles | -4.153 cycles |
| clean-victim miss响应 | 41.636 cycles | 31.448 cycles | -10.188 cycles |
| dirty-victim miss响应 | 65.679 cycles | 64.594 cycles | -1.085 cycles |
| 面积 | 69448.610 um^2 | 70378.812 um^2 | +1.34% |
| Fmax | 766.875 MHz | 750.362 MHz | -2.15% |
| max TNS | -457.502 | -967.029 | 恶化111.37% |
| `IPC * Fmax` | 276.083 MIPS | 272.228 MIPS | -1.40% |

当前`test`中dirty-victim占全部D-cache miss的66.290%，store也必须等待有序完成；因此该
候选只对少数clean-victim load miss产生明显收益。它增加的物理事务生命周期和路由保持
控制又落在现有LSU/数据路由关键路径组上，频率损失超过周期收益。候选在完整`train`前即
被同口径`test + STA`否决并从RTL删除，恢复后`test`精确回到1194972周期、0.360010 IPC。

后续若重新实现critical-load-first，必须把架构响应、line install、dirty writeback完成和
AXI路由释放定义为四个独立事件，并通过MSHR或writeback queue保存物理事务状态；不能把
“LSU已经收到数据”错误地当作“cache miss已经完全结束”。

### 单项延后完成槽否决实验

为减少blocking LSU期间的空发射，曾加入一个单项延后完成槽：较老LSU请求等待时，允许一条
不访问内存、无redirect且不会触发异常的年轻EX结果先保存，待较老LSU完成后再按程序顺序写回。
该方案不允许年轻结果越过较老指令提交，因此不是乱序提交，也没有破坏精确异常。

| 指标 | 保留基线 | 单项压缩延后完成槽 | 变化 |
| --- | ---: | ---: | ---: |
| `test` PMU周期 | 1194972 | 1191164 | -0.319% |
| `test` PMU IPC | 0.360010 | 0.361161 | +0.320% |
| 完整运行周期 | 2745651 | 2730115 | -0.566% |
| 面积 | 69448.610 um^2 | 70682.052 um^2 | +1.78% |
| Fmax | 766.875 MHz | 755.072 MHz | -1.54% |
| max TNS | -457.502 | -1219.390 | 恶化166.5% |
| `IPC * Fmax` | 276.083 MIPS | 272.7 MIPS | 约-1.2% |

该槽只能吸收一条年轻非访存指令，无法覆盖数十拍的cache miss或AXI等待；新增payload寄存器、
年龄门控和完成选择网络却处在已有execute/LSU反馈路径附近。周期收益小于面积和频率代价，
因此候选已经完整删除，恢复简单的有序completion mux。回滚后RV32、RV64定向流水线测试和
20步有界形式验证均通过；没有继续运行耗时的`train`，因为相同`test + STA`已经足以否决候选。

当前1 GHz约束下的保留基线最慢路径从`execute_packet`寄存器出发，经过EXU形成LSU请求、
LSU接收条件和数据子系统路由控制，到达`u_lsu.state_q`；数据到达时间为1.257 ns，要求时间
为0.953 ns，WNS为-0.304 ns，可达频率为766.875 MHz。CSR和PMU均不在最慢路径组中。
下一项频率候选必须在EX地址生成与LSU/cache请求接收之间建立真正的EX/MEM弹性边界，切断
下游ready反馈；不能继续在原组合路径上增加旁路选择或单项保存状态。

## 2026-09-05 - rv32-interview 完整流水线定时中断

- 基点：`bb03677d1ea6670059391328f1a61b69fb8f35ea`；本次修改在 `rv32-interview` 工作树，未作为历史 PPA 对应源码。
- 配置：RV32 baseline，I-cache 256 B/1 路/16 B 行，D-cache 256 B/2 路/16 B 行。
- 新增 CLINT mtimecmp 和 MTIP、CSR 使能、后端排空受理、独立中断陷入，以及 AM 定时事件。中断不伪造 commit。
- `make -C npc NPC_CONFIG=rv32-baseline git_commit= test-timer-interrupt`：退出码 0；3 次汇编系统运行各 11 次中断、2 次 AM 系统运行各 5 次中断，合计 43 次；另有 CLINT、控制器和 IFU 3 个单元测试通过。
- 汇编加入三个同组地址的脏替换与 FENCE.I；0/17/83 周期附加总线延迟下，中断 pending 与写事务分别重叠 173/391/635 个周期。核对提交 PC、恢复 PC、minstret、store 接受/提交数，以及软件数据自检。
- 新场景发现历史 FENCE.I 会撤回背压中的 I-cache 请求，触发原稳定性 SVA；修复为保持该请求并先排空，再执行数据缓存清理和指令缓存失效。保留断言后重新通过。
- 原有 `test-privileged test-pipeline test-lsu test-dcache test-uncached test-core-merge` 六项通过。最终整核 `lint-npc` 退出码 0，有未使用信号/参数等告警；未出现 LATCH、UNOPTFLAT、MULTIDRIVEN 或 PINMISSING。
- 日志：`npc/build/interview-audit/timer-regression.log`、`interrupt-existing-regression.log`、`interrupt-lint.log`，各单项日志在 `npc/build/tests/interrupt/`。
- 未验证：外部/软件中断、PLIC、完整 ysyxSoC/RT-Thread、异步中断 DiffTest；未重测综合面积与时序。

设计、地址表及复现方式见 [RV32 定时中断](../microarchitecture/TIMER_INTERRUPT_DESIGN_RECORD.md)。

## 2026-09-06 - RV32 中断版本纯核综合与 STA

`rv32-interview` 当前工作树，NanGate45 typ、rv32-baseline 小缓存、1 GHz、DELAY 0，Yosys/Slang + iEDA/iSTA，综合与 STA 退出 0。当前面积 78942.150 μm²、估算 Fmax 820.127 MHz，setup WNS −0.219 ns、TNS −834.600 ns；历史网表重查得到 69448.610 μm²、766.875 MHz、WNS −0.304 ns、TNS −457.502 ns，与旧记录一致。

面积增加 13.67%，估算频率增加 6.94%。时序单元面积增加 9416.932 μm²，DFF 从 7383 增至 9361；新旧网表的流水寄存结构不同，不能把全部变化归因于中断。统计不含核外 CLINT/SoC，1 GHz 尚未收敛，未进行物理实现，未重测 IPC。输入快照、工具脚本、哈希和原始报告均保留。详见 [完整复测报告](RV32_INTERRUPT_PPA_2026-09-06.md)。

## 2026-09-06 - 同一 RV32 网表在 820 MHz 下 STA

复用本日 1 GHz 综合所得网表，SHA-256 校验一致，仅以 CLK_FREQ_MHZ=820 重新运行 iSTA。程序退出 0，但时序未全部通过：setup WNS 显示 −0.000 ns、TNS −0.992 ns；min 最差 −0.062 ns、TNS −130.655 ns。最差 min 详细检查是 rst_ni→RN 的 removal，不应笼统视为普通数据 hold。门控 max/min 最差分别 +0.084/+0.101 ns。面积不变，未改 RTL 或复位 false-path。

报告与运行参数保存在 `npc/result/sta/rv32-interrupt-20260906/same-netlist-820MHz/`，详见 [PPA 报告的 820 MHz 复查](RV32_INTERRUPT_PPA_2026-09-06.md)。


## 2026-09-06：RV32 D-cache 写数据路径优化

只调整数据选择，不改变写入握手或 bypass；扩展 D-cache 和 5 组系统中断、3 组中断单元测试通过。面积 78,942.150 → 79,324.658 μm²（+0.48%），报告 Fmax 820.127 → 880.318 MHz；820 MHz setup WNS +0.083 ns、TNS 0，门控时钟 max/min 为正，复位 removal −0.062 ns 仍未修复。未增加流水级、未修改 SDC、未运行新 IPC 基准。详细证据见 [时序优化报告](RV32_TIMING_FIX_2026-09-06.md)。


## 2026-09-06：RV32 复位与重定向修复

预测后继 PC 提前寄存，纯核面积降至 78,871.394 μm²，原纯核估算 Fmax 903.898 MHz；1 GHz 尚未收敛。系统统一同步释放复位，映射后加入 96 个非反相复位缓冲单元。最终含复位控制器/缓冲树的纯核边界面积 79,002.532 μm²，在 820 MHz 下 max/min TNS 均为 0，最差 slack +0.036/+0.059 ns，门控时钟 +0.035/+0.099 ns。新增两项单元测试、流水控制及完整中断回归通过，复位网表审计和缓冲结构等价通过。无 CTS/布线签核。见 [完整报告](RV32_RESET_REDIRECT_FIX_2026-09-06.md)。


## 2026-09-06：当前 RV32 MicroBench test 复测

恢复 AXI SDRAM SoC 生成文件、配套外设修改和原有 PMU 窗口代码后，当前 RV32 核完成 MicroBench test，10 项通过、GOOD TRAP。PMU 累计 430,203 条指令、1,643,700 周期，IPC 0.261728；整次仿真 IPC 0.227295。较历史 1,194,972 周期增加 37.55%，尚需在统一 SoC/二进制环境下隔离版本定位，不能归因于单项修复。本轮没有修改 CPU RTL、没有重新测面积、没有运行 train/DiffTest。见 [完整报告](RV32_MICROBENCH_TEST_2026-09-06.md)。

## 2026-09-06：RV32 面积与 train IPC 探索

见 [完整实验记录](RV32_HARDWARE_OPTIMIZATION_2026-09-06.md)。先固定计分窗口与镜像，再逐项改变流水边界。基线与合并译码级的 test、STA 已完成，train 仍在运行。

## 2026-09-06：MicroBench 计时口径审计

当前及归档模型均确认：旧 CLINT 每 100 拍计 1 微秒，AXI/APB 延迟比例是 3037/1024，
没有随本轮 820 MHz STA 更新。旧环境 A/B 可比较周期，但不能当作校准到 820 MHz 的
系统性能；历史 train 的 4929.979 ms 也不能直接与来源条件未知的官方 4.49 s 比较。
新增 `NPC_SIM_CPU_FREQ_MHZ`，同时配置 CLINT 和设备延迟，并使用独立构建目录。
820 MHz 配置 test 全部通过，430,203 条指令 / 2,747,278 拍，IPC 0.156592，
Scored time 3.378 ms；完整 train 独立运行，结果待完成。2 倍与 8396/1024 倍 AXI
逐 beat 时间和独立读写测试通过。详细规则、原始模型参数证据及复现方式见
[计时审计](MICROBENCH_TIMING_RULES.md)。计时配置变化不计入硬件优化收益。


## 2026-09-06：完整 train 收齐，固定面试结构

上述进行中的 train 已全部完成。旧环境下，基线 670,929,314 拍 / IPC 0.278435，
合并译码 659,679,012 拍 / IPC 0.283184，当前第三方案 653,329,501 拍 / IPC 0.285936，
均退休 186,810,217 条指令、十项 PASS、GOOD TRAP。第三方案面积 78,163.036 μm²，
比基线少 1.06%，train IPC 高 2.69%，820 MHz STA 通过，予以保留。
显式 820 MHz 计时环境另测得 1,089,343,319 拍 / IPC 0.171489，计分 1.328498 s、
总计 1.953871 s；不同计时环境不作硬件加速比。完整记录见本轮硬件优化和计时报告。

面试结构、参数与依据已统一至 [RV32 设计选择](../interview/RV32_DESIGN_CHOICES.md)。
纠正旧审计中的 BTB 组数：16 是总项数，实际为 8 组×2 路；当前不再实例化 decode_stage。
