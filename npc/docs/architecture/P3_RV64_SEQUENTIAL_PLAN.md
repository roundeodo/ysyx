# P3 RV64 顺序处理器实施计划

状态：P3-E/P3-F/P3-G 已完成，P3-H 首版顺序流水线已通过双配置功能验证

最后更新：2026-08-24

## 1. 阶段目标

P3 先在现有多周期、单发射、顺序提交处理器上建立可运行的 RV64 功能基线，再进行顺序
流水化。这样可以分别验证 ISA 语义和流水线时序，避免在同一检查点同时引入两类错误。

P3 的第一个正式命名配置为 `YSYX_RV64_SEQUENTIAL`。首版 ISA 范围冻结为：

- RV64I；
- Zicsr；
- Zifencei；
- 仅 M-mode；
- 不包含 M、A、C、F、D、S-mode、U-mode、Sv39 和 Vector。

首版配置保持 32 位物理地址，但正式的 core/cache memory AXI 数据通路随 RV64 提升为
64 位。这样，`LD/SD` 在 core、cache 和主存互连之间保持一个 64 位 beat，不把当前开发板
环境的端口限制扩散进处理器微架构。

当前 ysyxSoC 的 CPU 插槽固定为 32 位 AXI，因此仅在 ysyxSoC system wrapper 中实例化
`AXI64 -> AXI32` 宽度转换器。该转换器属于特定 SoC 的集成边界，不属于 RV64 core 本身；
standalone NPC 和未来正式 SoC 均直接使用 64 位 memory AXI。

## 2. 命名配置

P3 必须长期保留以下两套可回归配置：

| 配置 | `XLEN` | core 数据 | 指令 | 物理地址 | memory AXI | ysyxSoC AXI | 用途 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `YSYX_RV32_BASELINE` | 32 | 32 | 32 | 32 | 32 | 32 | 课程回归和快速调试 |
| `YSYX_RV64_SEQUENTIAL` | 64 | 64 | 32 | 32 | 64 | 32 | RV64 多周期与顺序流水线基线 |

配置只能在编译期选择。package 中的类型宽度必须在 elaboration 时确定，因此不设计运行时
RV32/RV64 模式开关，也不在功能模块内部散布条件编译。

目标构建接口统一为：

```sh
make lint-npc PROJECT=riscv32 NPC_CONFIG=rv32-baseline
make lint-npc PROJECT=riscv32 NPC_CONFIG=rv64-sequential
```

不同配置必须使用独立构建目录，防止 Verilator 生成物和目标文件交叉复用：

```text
build/riscv32/rv32-baseline/
build/riscv32/rv64-sequential/
```

P2 使用过的临时 core64/AXI32 adapter 测试已经删除。P3 由上述两个正式构建配置直接决定
核心和 memory AXI 的静态宽度，不再使用测试宏模拟 RV64 配置。

### 2.1 ysyxSoC 的 RV64 支持结论

当前工作区中的 ysyxSoC **没有可直接启用的 RV64 模式**：

- `ysyxSoC/src/CPU.scala` 把 CPU master/slave 固定为 `addrBits = 32, dataBits = 32`；
- `ysyxSoC/src/Top.scala` 固定组合 `Edge32BitConfig` 和 `DefaultRV32Config`；
- `ysyxSoC/spec/cpu-interface.md` 规定 CPU 顶层的地址、读数据和写数据均为 32 位；
- AXI-to-APB、SDRAM 和各外设节点普遍使用 4-byte beat。

ysyxSoC 依赖的 Rocket Chip 框架本身包含 RV64 配置能力，但这不等于当前 ysyxSoC 顶层已经
支持 RV64。若把整个 ysyxSoC 原生升级为 AXI64，需要同步修改 CPU 插槽、edge 配置、宽度
转换、设备节点、生成 RTL、接口规范和验证环境，不能通过切换一个参数完成。

因此 P3 不立即改造整个 ysyxSoC。处理器正式接口使用 AXI64，而 ysyxSoC 继续作为 AXI32
验证平台，由 system wrapper 完成宽度转换。未来自研 SoC 不继承这项 32 位限制。

## 3. 固定不变量

1. RV64 基础指令仍为 32 位，`INSTR_WIDTH` 不随 `XLEN` 改变。
2. RV32I 和 RV64I 都有 32 个架构整数寄存器。
3. `x0` 在两个配置中始终读零且禁止写入。
4. 所有 RV64 `*W` 运算只计算低 32 位，再符号扩展到 64 位。
5. RV64 普通移位使用 6 位移位量，`*W` 移位使用 5 位移位量。
6. `LD/SD` 在 core memory AXI 上使用一个 64 位 beat；只有 ysyxSoC 边界转换器可以拆成
   两个 32 位事务，LSU 不直接操作 AXI channel。
7. PC、GPR、CSR、有效地址、物理地址和 AXI 地址继续使用不同语义类型。
8. RV32 回归失败时停止扩展，不允许等 RV64 全部完成后再修复基线。
9. 多周期 RV64 基线通过前不开始流水化。
10. MMIO 是否允许 64 位访问由 PMA 和设备契约决定；禁止自动拆分具有副作用的 MMIO 访问。

## 4. 实施顺序

### P3-A：建立正式双配置构建入口

状态：已完成（2026-08-14）。

修改范围：

- `npc/Makefile`：解析 `NPC_CONFIG`，只接受两个正式配置名，并为每个配置选择独立构建目录；
- `common/riscv_config_pkg.sv`：根据唯一构建宏导出配置常量，并把 memory AXI 宽度与
  ysyxSoC AXI 边界宽度分开命名；
- `filelist/` 和测试规则：传递配置宏，禁止测试宏泄漏到正常构建；
- 配置级 elaboration 检查：拒绝没有配置、同时选择两个配置和不支持的宽度组合。

本检查点不修改 IDU、EXU、LSU 和 CSR 功能。它只证明同一份源码能够以两套静态类型完成
预处理、elaboration 和 lint，并让 RV64 暂未实现的 ISA 语义以明确测试失败暴露出来。

退出条件：

- RV32 配置完成 elaboration 和 lint；dummy 属于后续功能回归；
- RV64 配置完成 elaboration 和 lint；
- 两个配置的构建产物位于不同目录；
- 非法 `NPC_CONFIG` 在 Make 阶段直接报错。
- RV64 配置可通过静态检查确认 `XLEN=64`、`CORE_DATA_WIDTH=64`、
  `MEM_AXI_DATA_WIDTH=64`、`YSYX_SOC_AXI_DATA_WIDTH=32`。

### P3-B：冻结公共 RV64I 语义和译码

状态：已完成（2026-08-20）。

修改范围：

- `common/riscv32_pkg.sv`：增加 RV64I 所需 opcode、ALU 操作和访存语义枚举；
- `core/riscv32_idu.sv`：实现 RV64I 合法性检查、立即数扩展和控制生成；
- Controller 或遗留重复译码不得重新出现，IDU 是指令语义进入 micro-op 的唯一所有者。

首批必须覆盖：

- `OP-IMM-32`：`ADDIW/SLLIW/SRLIW/SRAIW`；
- `OP-32`：`ADDW/SUBW/SLLW/SRLW/SRAW`；
- `LOAD`：`LWU/LD`；
- `STORE`：`SD`；
- RV64 普通移位与 `*W` 移位的不同 `shamt` 和编码合法性；
- RV64 下 `LUI/AUIPC` 的 32 位结果符号扩展规则。

退出条件：每条新增指令都有 directed decode test；非法编码不会产生寄存器写、访存或
redirect 副作用；RV32 译码回归不变。

完成内容：

- package 增加 `OP-IMM-32`、`OP-32`、`LD/LWU/SD` 编码，以及独立的 `ALU_*W`
  语义操作；译码阶段不把 `*W` 降级成普通 XLEN 运算；
- IDU 实现 `ADDIW/SLLIW/SRLIW/SRAIW`、`ADDW/SUBW/SLLW/SRLW/SRAW`、
  `LWU/LD/SD`，并区分 RV64 普通移位的 6 位 `shamt` 与 `*W` 移位的 5 位 `shamt`；
- RV64 的 `LUI/AUIPC` 立即数在 IDU 中按 32 位结果符号扩展到 XLEN；
- 非法编码保留指令身份和异常信息，但统一清除寄存器写、访存、CSR 写和 redirect 副作用；
- 新增双配置 directed decode test，RV32 明确拒绝 RV64 专属编码，RV64 覆盖全部 P3-B
  指令与关键非法编码。

验证命令：

```sh
make test-idu-configs PROJECT=riscv32
make lint-configs PROJECT=riscv32
```

验证结果：RV32 与 RV64 定向译码测试均通过，两套配置 lint 均无语法或 elaboration 错误。
本检查点只证明 micro-op 语义和合法性检查正确；`*W` 执行结果由 P3-C 实现，`LD/SD`
数据通路由 P3-D 实现。

### P3-C：实现 RV64 EXU 语义

状态：已完成。

修改范围：

- `core/riscv32_exu.sv`：增加所有 `*W` 运算；
- 普通算术、逻辑、比较和分支继续复用 `xlen_data_t` 数据通路；
- `*W` 运算必须显式截取低 32 位并符号扩展，不能依赖赋值截断产生隐式行为。

退出条件：RV64 ALU directed test 覆盖边界值、负数、移位量 31/32/63 和溢出回绕；RV32
结果逐项保持一致。

实现结果：

- EXU新增独立32位`word_result`通路，`ADDW/SUBW/SLLW/SRLW/SRAW`均先在低32位
  完成运算，再显式符号扩展到XLEN；
- `*W`寄存器移位统一使用`rs2[4:0]`，普通RV64移位仍使用6位移位量；
- 新增RV32/RV64双配置directed EXU test，覆盖普通运算回归、负数、32位溢出回绕、
  移位量31/32/63以及`*W`与普通RV64移位规则的隔离。

验证命令：

```sh
make test-exu-configs PROJECT=riscv32
make lint-configs PROJECT=riscv32
```

验证结果：RV32 与 RV64 定向 EXU 测试均通过；两套配置 lint 均无语法或 elaboration
错误。lint 仍报告若干由后续阶段负责的宽度与未使用字段告警，它们不影响 P3-C 的退出条件。

### P3-D：实现 RV64 LSU 和宽度边界

状态：已完成（2026-08-20）。

修改范围：

- `core/riscv32_lsu.sv`：实现 `LWU/LD/SD`、8 字节对齐、符号扩展和 8 字节 strobe；
- uncached adapter：core 侧 64 位语义请求直接生成 64 位 memory AXI 事务；
- I-cache refill adapter：使用 64 位 memory AXI beat 填充 cache line；
- ysyxSoC system wrapper：在处理器 AXI64 与现有 ysyxSoC AXI32 插槽之间完成拆分、合并、
  ID/响应保持和独立 AW/W channel 处理；
- PMA：明确哪些普通内存区域允许边界转换，哪些 MMIO 区域拒绝拆分访问；
- access fault 和拆分后的任一子事务出错时，只向上游返回一次完成响应。

64 位 MMIO 被拆成两个 32 位事务时不具备原子性，并且第一次访问就可能产生设备副作用。
P3 不用保护性兜底掩盖该事实：对不支持拆分的设备访问应由 PMA/adapter 在发出第一个子
事务前明确拒绝并产生 access fault。

退出条件：覆盖 `LB/LBU/LH/LHU/LW/LWU/LD`、`SB/SH/SW/SD`，覆盖对齐错误、AXI 反压和
第二个 beat 错误；新增的 AXI64 到 ysyxSoC AXI32 边界转换器定向测试通过。

实现结果：

- LSU实现`LWU/LD/SD`、8字节自然对齐、64位load格式化和8位store strobe；load请求不再
  携带无意义的写数据或strobe；
- uncached adapter收敛为core与memory AXI同宽的单beat转换，RV64 `LD/SD`直接生成
  `AxSIZE=3`、`AxLEN=0`事务，AW和W保持独立握手；
- standalone AXI memory及C++ DPI读写数据载体提升为64位，并按32/64位memory beat对齐，
  因而RV32与RV64共用同一仿真内存实现；
- PMA增加`width_conversion_supported`属性，只允许普通内存区域在ysyxSoC边界拆分；
  64位MMIO在任何下游AR/AW/W握手发生前返回`DECERR`；
- 新增独立的ysyxSoC AXI32类型package和system边界转换器。RV64普通内存读写拆成两个
  32位beat，保持ID，合并读数据，并汇总包括第二个read beat在内的错误；RV32配置使用
  无状态同宽直通路径；
- CLINT在64位memory AXI配置下支持对`mtime`进行一次64位原子读取，RV32继续使用低/高
  32位快照协议；
- I-cache refill继续通过参数化memory AXI读取32 B cache line；RV64下每个refill beat为
  64位，critical word仍按取指地址所在lane交付。

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

验证结果：LSU与uncached adapter双配置测试通过；AXI64到AXI32转换器覆盖窄访问lane、
AW/W独立反压、64位拆分、第二个read beat错误和宽MMIO无副作用拒绝；standalone双配置
完整构建通过；RV64 ysyxSoC lint通过；RV32 dummy在PC `0x80000030`命中good trap。
RV64软件镜像、64位DiffTest/DPI架构状态仍属于P3-F，不作为P3-D退出条件。

### P3-E：实现 RV64 CSR、异常和提交

状态：已完成（2026-08-20）。

修改范围：

- `core/riscv32_csr_file.sv`：检查 RV64 machine CSR 的可见位宽和 WARL 行为；
- trap controller：确保 `mepc/mcause/mtval`、异常 PC 和 redirect 目标均为 XLEN 语义；
- `core/riscv32_pmu.sv`：RV64 直接整宽访问 64 位计数器，RV32 保持高低半访问；
- commit：以架构提交事件驱动 `minstret` 和 DiffTest，不以执行完成代替退休。

首版只实现运行 AM 和 DiffTest 所需的 M-mode CSR，不在 P3 顺带加入 S/U-mode。

退出条件：`ecall/mret`、非法指令、取指/访存错误和未对齐异常均有 directed test；异常指令
不产生寄存器或存储器副作用；RV32 trap 回归保持通过。

实现结果：

- CSR file实现machine CSR的合法性、只读性和WARL约束，并补齐`misa`、`mimpid`、
  `mhartid`、`mtval`等DiffTest可观测状态；
- CSR写操作拆成“写意图”和“最终提交写入”，trap或非法CSR访问不会留下架构副作用；
- trap controller、commit和PMU统一使用XLEN架构状态，`minstret`仅由真实commit事件驱动；
- EXU对JAL/JALR目标做指令地址对齐检查；IDU明确将ECALL的`mtval`置零；
- 新增双配置特权级定向测试，覆盖CSR WARL、`ecall/mret`、非法指令、未对齐和
  access fault的精确异常语义。

验证命令：

```sh
make regression-p3-e PROJECT=riscv32
```

验证结果：RV32/RV64的privileged和EXU directed tests均通过。

### P3-F：建立 RV64 软件和参考模型

状态：已完成（2026-08-20）。

修改范围：

- Abstract Machine：增加 RV64 构建目标、启动代码、链接脚本、Context 和 trap 保存恢复；
- 工具链参数：首版固定为 `-march=rv64i_zicsr_zifencei -mabi=lp64`；
- NEMU：构建 RV64 reference，并与 standalone NPC 和 ysyxSoC 地址图分别匹配；
- NPC DiffTest：GPR、PC 和 CSR 状态使用 64 位布局，初始化镜像和寄存器同步按配置选择；
- 测试：增加 RV64 directed tests，不能只依赖编译器偶然生成某些指令。

退出条件：RV64 dummy、基础 cpu-tests、异常测试和 NEMU DiffTest 通过；RV32 软件目标与
reference 仍可独立构建。

实现结果：

- Abstract Machine新增`riscv64-npc`架构目标，固定使用
  `-march=rv64i_zicsr_zifencei -mabi=lp64`，并复用参数化的NPC启动和trap入口；
- RV64 NPC不再编译32位C软除法，而是使用AM中的RV64汇编除法实现；
- NEMU提供独立的RV32/RV64 reference配置和动态库，RV64I执行、CSR和trap状态与NPC对齐；
- NPC的PC、GPR、commit DPI和DiffTest架构状态改为按`NPC_XLEN`选择32/64位，
  比较GPR、PC、`mstatus/mtvec/mepc/mcause/mtval`；
- 新增`csr-trap`端到端测试，trap handler检查ECALL的`mcause=11`、`mtval=0`、
  `mstatus.MPIE/MIE`，修改`mepc`后通过`mret`返回。

验证命令：

```sh
make regression-p3-f-rv32 PROJECT=riscv32
make regression-p3-f-rv64 PROJECT=riscv32
```

验证结果：RV32和RV64各35项cpu-tests全部通过DiffTest。`unalign`测试要求硬件透明执行
非对齐访存，与当前“产生misaligned异常”的架构契约冲突，因此不属于本基线。

### P3-G：冻结 RV64 多周期功能基线

状态：已完成（2026-08-20，验证结果已固化，尚未创建基线提交）。

执行完整双配置回归并记录：

- lint、模块定向测试和AXI五通道反压；
- RV32/RV64 cpu-tests；
- RV32/RV64 DiffTest；
- AM 基础程序；
- PMU 周期、退休指令、IPC、IFU/LSU 延迟；
- 综合面积、WNS 和关键路径。

退出条件是形成可复现的 `YSYX_RV64_SEQUENTIAL` 多周期基线 commit。只有这个检查点通过，
才能改变流水级边界。

实现结果：

- `make regression-p3-g PROJECT=riscv32`成为唯一的完整回归入口，依次执行双配置模块测试、
  standalone/SoC lint、双配置构建、RV32/RV64 DiffTest和双配置STA；任一步失败都会停止；
- RV32和RV64各35项cpu-tests全部通过DiffTest；配置、IDU、EXU、LSU、uncached AXI4、
  privileged/commit/PMU测试均在两套配置下通过，RV64到ysyxSoC AXI32转换测试通过；
- uncached master和SoC宽度转换器定向覆盖AR、R、AW、W、B反压、payload保持、AW/W独立
  握手以及错误响应。固定序列保证基线可复现；随机化协议验证在P3-H验证基础设施中增加；
- Yosys使用Slang读取完整SystemVerilog compilation unit，综合策略固定为`DELAY 0`；完整core
  不再使用代价不可控的aggressive SAT sharing；
- 当前PDK没有I-cache SRAM macro及其Liberty模型，因此STA将tag/data array作为黑盒，只评估
  core、cache controller和AXI逻辑壳。报告不包含SRAM面积与访问延迟，不能冒充最终签核结果；
- 功耗分析改成显式选项`STA_RUN_POWER_ANALYSIS=1`，默认STA只生成面积与时序基线，避免
  vectorless power graph拖慢每次功能回归。

验证命令：

```sh
make regression-p3-g PROJECT=riscv32
```

300 MHz约束下的逻辑壳基线：

| 配置 | 标准单元面积 | 时序单元面积 | WNS | TNS | 报告频率 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `rv32-baseline` | 38183.32 | 18138.12 | +0.068 ns | 0.000 ns | 306.307 MHz |
| `rv64-sequential` | 58743.44 | 27738.76 | -0.366 ns | -114.307 ns | 270.373 MHz |

RV64逻辑壳面积比RV32增加约53.85%，时序单元面积增加约52.93%，报告频率下降约11.73%。
RV64关键终点位于架构寄存器堆写回路径；这为P3-H拆分执行/写回组合路径提供了直接依据。

`hello-str`的PMU基线为：RV32退休1862条、7011周期、IPC 0.265583；RV64退休1876条、
7100周期、IPC 0.264225。两套配置的IFU平均响应延迟约2.14周期，说明当前多周期吞吐主要
受每条指令串行取指/执行限制，而不是64位功能本身造成数量级退化。

### P3-H：顺序流水化

状态：首版已完成（2026-08-24）。

在相同 RV64 ISA、cache、LSU、CSR、commit 和验证接口上引入分级流水线，再实现旁路、冒险、
flush 和精确异常。流水化不能创建第二套译码或第二套架构状态。

当前实现加入`decode_execute_stage`和`writeback_stage`两个弹性寄存器；IFU/I-cache已有的
valid/ready保持承担前端边界。hazard controller首版采用无forwarding RAW停顿、blocking
LSU结构停顿和串行化排空；EX redirect只清除年轻ID/EX内容，commit trap/`mret`/`fence.i`
同时阻止年轻completion进入WB。详细契约见
[`PIPELINE_DESIGN_RECORD.md`](../microarchitecture/PIPELINE_DESIGN_RECORD.md)。

RV32和RV64各35项CPU/异常DiffTest全部通过，双配置lint、流水级定向测试和LSU定向测试
通过。RV32 MicroBench `test`通过，PMU窗口退休430203条指令、执行2157726周期，IPC为
0.199377。当前结果是无forwarding、无分支预测和blocking LSU的保守正确性基线，不是
流水线性能终点。

## 5. 推荐的单步验证纪律

每个检查点均按以下顺序执行：

1. formatter 和 lint；
2. 当前模块 directed test；
3. RV32 dummy；
4. RV32 cpu-tests；
5. 当前已具备的 RV64 directed tests；
6. 集成 DiffTest；
7. 更新实验日志后再提交检查点。

如果某一步失败，只修复当前检查点负责的边界，不提前进入下一模块。

## 6. 当前第一项任务

依据RAW、控制flush和LSU结构等待计数实现forwarding。forwarding只能改变冒险控制和操作数
选择，不能改变commit、异常或AXI/cache契约。随后增加分支预测；D-cache仍按架构计划在
顺序流水线稳定后实现。
