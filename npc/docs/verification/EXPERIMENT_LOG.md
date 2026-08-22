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
