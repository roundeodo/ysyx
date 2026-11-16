# RV32高性能CPU架构计划

> **归档说明**：这是2026-07-30以前的RV32路线快照，只用于追溯当前RTL的形成过程，
> 不再具有设计约束力。当前权威计划是
> [`../ARCHITECTURE_PLAN.md`](../ARCHITECTURE_PLAN.md)。

状态：已归档，非当前规范

当前已验证检查点：P3B - ysyxSoC完整AXI边界及CPU本地CLINT

当前设计工作流：P5A - I-cache契约及教学RTL骨架

最后更新：2026-07-30

## 1. 文档目的

归档前，本文档曾是`npc/vsrc/riscv32` CPU的设计权威，用于固定长期架构、模块所有权、接口规则、
命名和实施顺序，防止后续局部修改把整体设计带向互相冲突的方向。

本文中的“必须”“禁止”“应该”和“可以”具有规范约束力：

- 现有RTL TODO必须遵守本文档。
- TODO与本文档冲突时，以本文档为准，并且必须先更新TODO再编写RTL。
- 禁止仅为了简化一个局部模块而修改本文档中的设计决策。
- 真正的架构变更必须先在第16节增加决策记录，再修改代码。

## 2. 项目目标

### 2.1 当前目标

使用一个正确的RV32I处理器完成ysyx C阶段要求：

- 当前阶段要求的RV32I整数指令。
- M模式CSR指令以及`ecall`、`ebreak`和`mret`。
- AM和RT-Thread所需的精确异常及定时器中断。
- 基于已提交指令的SDB、itrace、mtrace、ftrace和DiffTest。
- 可综合CPU core，DPI只能存在于仿真适配器中。

### 2.2 长期目标

构建一个32位高性能core：

- 只支持RV32I这一种基础整数ISA配置。
- 每个实施阶段都提供32个架构整数寄存器（`x0-x31`）。
- 目标ISA配置为`RV32IM_Zicsr_Zifencei`；`C`、`A`和选定的`B`扩展只在后续阶段加入。
- 显式物理寄存器重命名。
- 乱序发射和执行，顺序提交。
- 双宽取指、译码、重命名、分派和提交。
- 分离整数发射队列和访存发射队列。
- ROB、LSQ、store buffer、分支预测和精确恢复。
- 分离的指令/数据cache及外部总线适配器。

RTL必须保留完整的5位架构寄存器命名空间并实现全部32个RV32I整数寄存器。IDU禁止
拒绝`x16-x31`。这样可以从译码、寄存器重命名、DiffTest和软件ABI中删除一个不必要的
配置维度，同时让编译器继续使用32个可见寄存器完成循环展开、软件流水和cache分块。

## 3. 参考设计

本项目不照搬某一个处理器，而是采用多个开源实现中所有权和行为均清晰的机制。

| 项目 | 相关特性 | 本项目采用的决策 |
| --- | --- | --- |
| [Ibex](https://ibex-core.readthedocs.io/en/latest/03_reference/pipeline_details.html) | 可配置RV32E/RV32I，明确的IF和ID/EX级，可选WB级 | 保持清晰的IFU和IDU边界；多周期操作支持背压 |
| [CV32E40P](https://cv32e40p.readthedocs.io/en/latest/pipeline.html) | 具有明确IF、ID、EX、WB行为的四级RV32顺序流水线 | 在引入OoO状态前作为功能正确的顺序检查点 |
| [VeeR EH1](https://github.com/chipsalliance/Cores-VeeR-EH1) | 按IFU、decode、EXU和LSU组织的高性能RV32 core | 保留可识别的流水级/功能单元边界，并验证双宽RV32操作 |
| [RSD](https://github.com/rsd-devel/rsd) | RV32IMF OoO core，双取指、多发射、64条在途指令、重放、推测访存和非阻塞cache | 证明所选RV32 OoO方向可用SystemVerilog实现的主要参考 |
| [BOOM Rename](https://docs.boom-core.org/en/latest/sections/rename-stage.html) | 显式PRF重命名、映射表、busy table、free list、旧目的寄存器和分支检查点 | 采用显式重命名，并在提交时释放物理寄存器 |
| [BOOM ROB](https://docs.boom-core.org/en/latest/sections/reorder-buffer.html) | ROB跟踪在途状态并提供精确顺序提交 | ROB是唯一的指令年龄权威和异常排序结构 |
| [BOOM Issue](https://docs.boom-core.org/en/latest/sections/issue-units.html) | 分离发射队列以及操作数就绪唤醒/选择 | 使用独立整数和访存发射队列 |
| [BOOM LSU](https://docs.boom-core.org/en/latest/sections/load-store-unit.html) | load/store队列、store-to-load转发、推测load和顺序恢复 | 使用LSQ；store只能在提交后对外可见 |
| [BOOM Fetch](https://docs.boom-core.org/en/latest/sections/instruction-fetch-stage.html) | fetch packet和流通式fetch buffer将I-cache响应与译码解耦 | fetch buffer与cache查找/refill的所有权分离 |
| [Ibex I-cache](https://ibex-core.readthedocs.io/en/latest/03_reference/icache.html) | 分级查找、fill buffer、关键字优先refill、直通和失效 | 使用分级查找、提前重启、uncached旁路和显式`fence.i`失效 |
| [香山I-cache WayLookup](https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/frontend/ICache/WayLookup/) | 分离阵列、主流水线、miss/refill、替换、元数据队列、旁路和flush处理 | 保留这些所有权边界，第一版只支持一个阻塞miss |
| [香山后端](https://docs.xiangshan.cc/projects/design/en/kunminghu-v3/backend/) | Decode、Rename、Dispatch、Schedule、Issue、Execute、Writeback和Retire职责分离 | 使用相同的所有权词汇，初始宽度保持较小 |
| [OpenTitan硬件设计文档](https://opentitan.org/book/doc/contributing/hw/design.html) | 工作原理、接口契约、设计细节、DV目标和断言 | 本地模块设计记录采用同样的证据导向结构 |
| [RISC-V RV32I](https://docs.riscv.org/reference/isa/unpriv/rv32.html) | 具有32个架构整数寄存器的基础整数ISA | 标准32寄存器命名空间是唯一支持的基础配置 |

## 4. 冻结的顶层架构

目标数据流如下：

```text
top
  -> riscv32_core
       -> riscv32_ifu
            -> riscv32_branch_predictor
            -> riscv32_fetch_queue
            -> instruction memory interface
       -> riscv32_idu
            -> optional riscv32_decode_lane[DECODE_WIDTH]
       -> riscv32_rename
            -> riscv32_rename_map
            -> riscv32_free_list
            -> riscv32_busy_table
       -> riscv32_dispatch
            -> riscv32_rob
            -> riscv32_int_issue_queue
            -> riscv32_mem_issue_queue
       -> execution cluster
            -> riscv32_int_alu[INT_ISSUE_WIDTH]
            -> riscv32_branch_unit
            -> riscv32_muldiv
            -> riscv32_csr_exec
            -> riscv32_agu
       -> riscv32_lsu
            -> riscv32_lsq
            -> riscv32_store_buffer
            -> data memory interface
       -> riscv32_completion_network
            -> riscv32_phys_regfile
            -> riscv32_busy_table wakeup
            -> riscv32_rob completion
       -> riscv32_commit
            -> committed rename map/free
            -> committed CSR/store/trap effects
            -> commit trace
       -> riscv32_trap_ctrl
       -> riscv32_redirect_arbiter

top
  -> riscv32_sim_mem
  -> riscv32_sim_debug
```

禁止设置集中式`Controller`模块。控制按所有权分布：

- IDU负责把ISA编码翻译成uop。
- Rename负责寄存器映射。
- 发射队列负责就绪状态和选择。
- 功能单元负责执行语义。
- ROB负责指令年龄和提交资格。
- Commit负责授权架构副作用。
- Trap control负责trap和中断状态转移。
- Redirect arbiter负责选择恢复来源。

## 5. 模块所有权

| 模块 | 负责 | 禁止负责 |
| --- | --- | --- |
| `top` | 时钟/复位外壳、仿真适配器 | ISA译码、CPU状态、分支恢复策略 |
| `riscv32_core` | 可综合CPU模块的结构连接 | DPI调用或仿真器特定存储行为 |
| `riscv32_ifu` | 取指PC、取指请求流、预测器和fetch queue集成 | 架构异常或ROB内部状态 |
| `riscv32_idu` | 字段提取、立即数、合法性和uop生成 | 寄存器值、CSR写、redirect、DPI调用 |
| `riscv32_decode_lane` | 单条指令的纯组合译码 | valid/ready流或多lane顺序 |
| `riscv32_rename` | 逻辑到物理映射和同周期lane旁路 | 执行、结果数据、访存顺序 |
| `riscv32_dispatch` | 向ROB和发射结构原子分配资源 | 重复译码opcode或选择就绪指令 |
| `riscv32_*_issue_queue` | 操作数就绪、唤醒、年龄选择和FU可用性 | 更新架构状态 |
| `riscv32_phys_regfile` | 推测及已提交整数值 | 逻辑寄存器映射或提交顺序 |
| `riscv32_rob` | 在途年龄、完成状态、最老异常和提交候选 | ALU数据选择或cache请求 |
| 执行单元 | 产生操作专属结果和异常 | 提交决策或ISA opcode译码 |
| `riscv32_lsq` | load/store顺序、转发、违例检测和重放元数据 | 外部总线协议 |
| `riscv32_store_buffer` | 排出已提交store | 让未提交store对外可见 |
| `riscv32_completion_network` | 多来源writeback路由和冲突处理 | 决定架构提交顺序 |
| `riscv32_commit` | 授权有序GPR映射、CSR、store、trap和trace副作用 | 执行指令或跟踪任意发射年龄 |
| `riscv32_csr_file` | CSR架构状态 | 执行CSR指令或redirect仲裁 |
| `riscv32_csr_exec` | 计算CSR旧值/新值并检查合法性 | 在提交前更新CSR状态 |
| `riscv32_trap_ctrl` | 提交边界上的trap/中断/mret转移 | 通用指令译码 |
| `riscv32_redirect_arbiter` | 选择一个恢复请求并产生flush边界 | 检测分支条件或修改CSR状态 |

## 6. IDU和decoder决策

`riscv32_idu`是永久的外部模块边界。

它接收一条或多条取指记录并产生一条或多条`decoded_uop_t`，负责lane顺序、valid/ready
流、输出压缩和背压。

`riscv32_decode_lane`是可选内部实现。只有当`DECODE_WIDTH > 1`且复制纯组合译码具有
价值时才创建它。每个lane把一条指令映射为一个已译码uop，但它不拥有独立流水级。

因此：

- 文档中保留IDU这一概念名称。
- SystemVerilog标识符使用小写蛇形命名`riscv32_idu`。
- 禁止恢复独立顶层`Controller`。
- 禁止通过`top.sv`暴露分散的opcode/funct/immediate连线。
- IDU中不读取寄存器文件；操作数值应在rename和issue后读取。

## 7. 规范内部类型和通道

package必须为每条指令或每个请求定义一个载荷：

- `fetch_entry_t`：`pc`、`instruction`、预测元数据和取指异常元数据。
- `decoded_uop_t`：架构寄存器索引、操作数使用位、立即数、FU类型、内部操作、CSR字段、
  串行化和异常元数据。
- `renamed_uop_t`：已译码uop加上`psrc1`、`psrc2`、`pdst`、`stale_pdst`和`rob_idx`。
- `int_execute_req_t`、`branch_execute_req_t`、`lsu_execute_req_t`和
  `csr_execute_req_t`：操作专属源操作数、控制和年龄标签。
- `completion_t`：结果、目的寄存器、ROB标签、异常、分支恢复和重放数据。
- `mem_req_t`和`mem_resp_t`：内部cache/存储协议载荷。
- `redirect_req_t`：目标PC、原因、ROB年龄和flush边界。
- `commit_t`：一条已退休指令及其全部架构可见副作用。

多宽接口使用每lane载荷的非紧凑数组。载荷禁止包含所属通道的`valid`或`ready`位。

每条弹性通道采用：

```systemverilog
payload_t payload_o [WIDTH];
logic     valid_o   [WIDTH];
logic     ready_i   [WIDTH];
```

通道规则：

1. 只有`valid && ready`为真时才发生传输。
2. `valid`为真且`ready`为假时，产生者必须保持载荷和`valid`稳定。
3. 只有有效lane中的载荷字段才有意义。
4. 模块禁止跨越多个流水级形成ready-to-valid组合环路。
5. flush不能编码成ready。flush是带年龄边界的独立恢复事件。
6. 宽度必须是模块参数，不能手工复制多套不同名称的连线。
7. 每个延迟敏感边界都必须评估同周期旁路。只有在载荷稳定性、事务身份、顺序和精确
   恢复均得到保证，且静态时序证明组合路径可行时，才实现旁路。旁路禁止引入
   ready-to-valid环路，也不能删除保存停顿事务所需的寄存器回退路径。

P0使用相同通道契约但不加入流水级存储。ready从宽度为1的commit接收端组合传播，IFU
只在`fetch_valid && fetch_ready`或redirect时推进PC。这样既维持每周期一条指令，又让
后续stall和流水级寄存器成为局部修改。P0禁止增加ready-to-valid组合依赖。

## 8. 宽度和资源策略

验证结构期间，所有宽度从1开始。最终教学目标为：

| 参数 | 初始值 | 目标值 |
| --- | ---: | ---: |
| `FETCH_WIDTH` | 1 | 2 |
| `DECODE_WIDTH` | 1 | 2 |
| `RENAME_WIDTH` | 1 | 2 |
| `DISPATCH_WIDTH` | 1 | 2 |
| `COMMIT_WIDTH` | 1 | 2 |
| `INT_ISSUE_WIDTH` | 1 | 2 |
| `MEM_ISSUE_WIDTH` | 1 | 1 |
| `ROB_ENTRIES` | 8 during bring-up | 32, then evaluate 64 |
| `INT_PHYS_REGS` | 48 | 64 |
| `INT_IQ_ENTRIES` | 4 during bring-up | 16 |
| `MEM_IQ_ENTRIES` | 4 during bring-up | 12 |
| `LQ_ENTRIES` | 2 during bring-up | 8 |
| `SQ_ENTRIES` | 2 during bring-up | 8 |

这些参数彼此独立。设计禁止假设取指宽度等于发射宽度，也禁止假设每个执行单元都能接收
每种uop。

completion network的目标是每周期至少支持两项会产生寄存器结果的completion。全局唯一
胜者的completion arbiter只允许在宽度为1的启动阶段使用，禁止成为最终接口。

## 9. Rename、ROB和精确状态

OoO core使用显式物理寄存器重命名：

- 推测rename map：当前逻辑到物理映射。
- 已提交rename map：精确架构映射。
- Free list：未使用物理寄存器。
- Busy table：每个物理寄存器的就绪状态。
- 物理寄存器文件：推测值和已提交值。
- 旧目的寄存器：只有替代它的指令提交时，才释放此前映射。

在双宽rename周期内，较年轻lane必须看到同周期较年长lane建立的映射。`x0`始终映射到
物理寄存器0，且永不分配新物理目的寄存器。

ROB是程序顺序的唯一权威。每个表项至少记录：

- 有效和已完成状态。
- PC和指令身份，或对它们的引用。
- 架构目的寄存器和旧物理目的寄存器。
- 异常有效位、原因和trap value。
- 分支/恢复元数据。
- CSR、store、fence和串行化元数据。

执行可以乱序完成，但提交始终按程序顺序。每条年长指令达到可安全提交状态前，年轻指令
不能产生异常、接受中断、写CSR、让store对外可见或更新架构rename map。

分支检查点保存足够的推测rename/free-list状态，以实现快速恢复。异常恢复使用已提交
rename map。ROB walking可以作为调试或降低面积的模式存在，但不是目标高性能恢复机制。

## 10. 执行和completion

IDU选择具有语义的`fu_type`和操作，执行单元禁止再次译码原始opcode。

必需执行单元：

- 整数ALU：加减、逻辑、移位和比较。
- 分支单元：计算条件、目标地址并验证预测。
- AGU：计算load/store有效地址。
- CSR执行单元：原子计算CSR旧值和新值。
- 启用M扩展时，使用迭代式或流水式乘除单元。

每个单元接收操作专属请求载荷并产生`completion_t`。精简请求载荷可以避免无关CSR、
访存和分支位进入发射队列、旁路路径和执行单元输入mux。completion负责：

- 需要时写回物理寄存器。
- 唤醒busy table。
- 更新ROB完成状态。
- 提前产生分支或访存重放redirect请求。

completion不提交架构状态。

## 11. LSU和访存顺序

LSU只接收访存uop，非访存指令永不经过LSU。

目标存储子系统包含：

- 计算有效地址的AGU。
- Load queue和store queue。
- Store-to-load转发。
- 较老store地址或数据尚未确定时的load重放。
- 访存顺序违例检测和恢复。
- 只接受已提交store的store buffer。
- MMIO分类；禁止推测MMIO请求。

load可以推测执行。store可以推测计算地址和数据，但在提交前禁止对外可见。目标存储模型
是RVWMO。原子指令延后到A扩展阶段，且必须复用相同的顺序结构，不能绕过它们。

内部指令/数据存储通道与DPI、AXI或具体cache实现无关。仿真DPI和SoC总线协议终止在
core外部的适配器中。

## 12. CSR、异常、中断和redirect

CSR指令执行与CSR架构状态分离：

1. `riscv32_csr_exec`读取旧值、检查合法性并计算候选新值。
2. completion记录旧值、新值和所有异常。
3. 只有已提交CSR指令才能更新`riscv32_csr_file`。

`ecall`、`ebreak`、非法指令、非对齐访问、access fault和未来page fault都是随uop/ROB
携带的异常元数据，不能直接从IDU发起redirect或终止仿真。

Trap和中断行为：

- 同步异常只在异常指令位于ROB头时处理。
- 中断只在可安全提交边界接受。
- trap入口更新`mepc`、`mcause`、`mtval`和`mstatus`，然后redirect到`mtvec`。
- `mret`只在提交时更新`mstatus`并redirect到`mepc`。
- `mcycle`每周期递增；`minstret`按已提交指令数量递增。
- `ebreak`通过commit事件到达`riscv32_sim_debug`；IDU永不调用DPI。

redirect来源包括分支预测错误、访存顺序重放、已提交trap、已提交`mret`和debug。redirect
请求包含指令年龄和flush边界。已提交架构redirect优先于推测redirect；否则选择引发恢复
的最老指令。

## 13. 验证契约

Trace和DiffTest观察commit，不能观察fetch、decode、execute或原始writeback。

每条已提交lane导出一项`commit_t`，至少包含：

- PC、指令和下一PC；通道valid与`commit_t`分离。
- 架构GPR写使能、地址和数据。
- CSR写元数据。
- 需要时提供load/store地址、数据、掩码和已提交可见性。
- 异常/中断原因和trap value。
- 扩展特权模式后，提供特权模式。

必须完成的验证层次：

1. Verilator lint，不允许出现意外warning。
2. decoder、ALU、branch、CSR、rename、ROB、issue queue和LSQ的定向单元测试。
3. RV32I ISA测试。
4. 每条已提交指令执行一次NEMU DiffTest，按lane和程序顺序处理。
5. 随机存储延迟和背压。
6. 通道稳定性、禁止重复分配、禁止物理寄存器泄漏、禁止年轻指令先提交、x0不变量、
   ROB/LSQ边界和flush正确性断言。
7. rename旁路、issue select、completion路由、分支redirect和cache访问路径的综合/STA
   检查点。

仅仅能运行一个小测试程序，不能说明任何阶段已经完成。

## 14. 实施路线图

### P0 - 可运行的单周期RV32I基线

- 在两次架构状态更新之间保留一条完整组合指令路径。
- 使用带类型的点对点载荷和独立valid/ready信号；valid不能放进载荷，本阶段不增加流水级
  寄存器。
- 译码保留在IDU内，top只负责连接。
- 只有访存操作经过LSU；直接执行结果和访存结果在宽度为1的completion边界合并。
- 产生宽度为1的`commit_t`；GPR/CSR/trap/debug副作用均在此授权。由于没有年轻指令
  在途，P0 store可以在同一末端fire上执行。
- 暂时保留现有DPI访存；清理内部契约时不引入stall或流水寄存器。
- 实现`x0-x31`、CSR/trap行为、trace、DiffTest和当前ysyx测试。
- 每次修改模块接口后编译并运行完整检查点。

退出标准：采用类型化模块边界的单周期NPC通过lint、cpu-tests、dummy、yield-os、trace和
DiffTest。

### P1 - 存储端口和仿真适配器边界

- 为IFU和LSU提供显式的指令/数据存储请求与响应端口。
- 把所有存储DPI调用移入`riscv32_sim_mem`；使用完整的请求valid/ready和响应
  valid/ready协议，实现固定一周期响应。
- 为IFU和LSU分别增加本地事务状态，使请求和响应可以跨周期保存；禁止增加全局多周期
  控制器。
- 将可综合的`riscv32_core`与仿真top、debug适配器分离。
- CPU变为分布式多周期实现，每个端口最多保留一个未完成事务。
- DPI必须从可综合core中移除，但不要求从仿真外壳中移除。在具备可综合的镜像加载路径
  之前，DPI适配器继续负责程序镜像和MMIO的功能后端。

退出标准：通过与P0相同的测试，且`riscv32_core`内部没有模块调用DPI。

### P2 - 可变延迟SimpleBus验证

- 在不修改任何core侧端口的前提下，为P1固定延迟DPI slave增加独立的请求/响应背压和
  可变延迟。
- 在请求及响应停顿下验证P1的IFU/LSU本地状态。初始IFU状态保持为发送请求、等待响应和
  保存取指结果；初始LSU状态保持为接收uop、发送请求、等待响应和保存执行结果。
- 保留DPI仿真slave处理镜像、MMIO、trace和DiffTest。真实存储器及外设slave在SoC集成
  阶段引入，不属于P2。
- 测试随机存储延迟和背压。

core虽然暴露分离的指令和数据端口，但系统功能地址空间仍然统一。因此，
`riscv32_sim_mem`把两个端口映射到同一个C++ `pmem`。后续I-cache和D-cache是在统一下层
存储器前增加的两个协议端点。

退出标准：全部现有软件和DiffTest在固定及随机存储延迟下通过，请求停顿期间所有架构
状态保持稳定。

### P3 - 标准总线和SoC集成

- 协议转换放在`riscv32_core`之外。
- 先引入AXI4-Lite或ysyx当前要求的总线；只有需要burst和多个未完成事务时才升级为完整
  AXI4。
- 逐步加入地址选择、SRAM、定时器/CLINT、UART及其他SoC外设。
- 每个外设和总线适配器必须独立验证后，才能继续集成下一个模块。

退出标准：非流水core通过SoC总线启动并运行AM/RT-Thread。

### P4 - 解耦顺序流水线

- 只有总线侧CPU稳定后，才增加valid/ready流水级寄存器。
- 实现前递、相关检测、load-use停顿、redirect冲刷和背压。
- 增加宽度为1的commit边界，并让trace/DiffTest消费`commit_t`。
- 确保GPR、CSR、store、trap和中断副作用都由commit授权。

退出标准：流水core在随机总线延迟下通过DiffTest和RT-Thread。

### P5 - 拆分执行单元和cache层次

- 拆分整数ALU、分支单元、AGU、CSR执行和乘除执行路径。
- 增加与commit分离的completion network。
- 以可测量、可回归的步骤加入I-cache、D-cache、store buffer、fetch queue和分支预测。
- 非访存uop禁止进入LSU，未提交store禁止对外可见。

退出标准：每个执行/cache单元都有定向测试，每项性能特性都产生可测收益且不引入DiffTest
回归。

#### P5A - 第一个指令cache检查点

在P4实施前先完成I-cache设计，使其接口和状态所有权不依赖临时的IFU直连AXI控制。在P3B
检查点仍可运行且cache子模块通过单元检查之前，禁止把I-cache加入有效filelist。P4仍是下
一个CPU执行架构检查点；提前设计I-cache不代表可以跳过流水线验证。

- 冻结第一版配置：8 KiB、2-way、32字节cache line、128个set和一个阻塞式miss表项。
- IFU侧使用与下层协议无关的查找通道，AXI只存在于cache下方的refill adapter中。
- 按所有权拆分PMA、tag array、data array、miss unit、refill adapter和fetch buffer。
- 使用兼容同步阵列的S0/S1/S2查找分级：请求/索引、阵列响应、tag比较/way选择。
- 按关键字优先顺序补充8个32位word，并支持提前重启。只有整条cache line成功接收后，
  metadata才能被标记为present。
- 在查找响应中携带`frontend_tag`和取指epoch，并在miss/refill边界使用独立的refill事务
  索引，使redirect可以丢弃过时工作而不破坏下层协议。
- 第一版即实现`fence.i`失效和PMU事件。
- 设计和实验分别记录在
  [`npc/docs/microarchitecture/ICACHE_DESIGN_RECORD.md`](../../microarchitecture/ICACHE_DESIGN_RECORD.md)
  和[`npc/docs/verification/EXPERIMENT_LOG.md`](../../verification/EXPERIMENT_LOG.md)。

P5A退出标准：array、refill、miss、redirect、失效、错误及背压测试通过；cache启用和禁用
时完整回归均通过；microbench测量结果显示IFU响应等待周期减少、IPC提高，且未引入新的
时序违例。

### P6 - Width-1 out-of-order skeleton

- 增加显式rename map、committed map、free list、busy table和物理寄存器文件。
- 增加ROB、分离的发射队列、LSQ和已提交store buffer。
- 宽度保持为1，用于验证所有权、精确恢复和资源守恒。
- 增加分支检查点和重复flush/recovery压力测试。

退出标准：随机乱序完成结果在顺序提交点与NEMU一致。

### P7 - Two-wide superscalar core

- 将fetch/decode/rename/dispatch/commit目标宽度设为2。
- 增加同周期rename旁路和多资源原子分派。
- 增加多个执行/completion端口，并在commit保持lane和程序顺序。
- 验证部分lane接收、ROB回绕、同时异常和恢复。

退出标准：双lane相关、分支、异常和访存压力测试通过。

### P8 - Performance and ISA expansion

- 增加非阻塞cache、miss跟踪、访存相关预测和重放。
- 测量IPC、分支MPKI、cache MPKI、ROB占用率、发射队列占用率和重放率。
- 只有具备独立设计与验证计划时，才加入C、A、选定的B扩展、S/U模式和MMU。

## 15. 命名和源码布局

所有RTL命名和源码组织必须遵守
[`NAMING_GUIDE.md`](../../development/NAMING_GUIDE.md)。该文档是精简的
代码风格检查表，本节只定义架构专用词汇。

RTL标识符采用[lowRISC SystemVerilog风格](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md)：

- 文件和模块：`lower_snake_case`，每个文件只放一个主要模块。
- 实例：`u_<role>`。
- 输入/输出端口：分别使用`_i`和`_o`后缀。
- 寄存器当前值/下一值：分别使用`_q`和`_d`后缀。
- 结构体/类型：`_t`；枚举类型：`_e`。
- 低有效复位：`rst_ni`。
- 常量：`UPPER_SNAKE_CASE`。

时序逻辑按状态所有权划分。当一个模块包含多个彼此独立且内聚的状态组时，可以使用多个
`always_ff`，例如定时器、AXI读通道和AXI写通道。每个时序块应放在该状态组的声明及
next-state逻辑附近。每个寄存器仍然必须只有一个`always_ff`驱动；禁止把同一个状态组
拆散到互不相关的位置。

保留`ifu`、`idu`、`alu`、`lsu`、`csr`、`rob`、`lsq`和`prf`等常用架构缩写，但在
SystemVerilog标识符中统一使用小写。禁止引入`RDU`或`WBU`这类含义不明确的缩写。

通道名称必须描述当前协议角色，不能使用更早的产生流水级来命名：

- 事务使用`*_req`和`*_resp`；`valid`/`ready`保持为独立信号。
- 只有指定操作已经完成后才能使用`*_result`。EXU到LSU的流量应命名为`lsu_req`，不能
  命名为`memory_result`，因为该边界还没有产生存储响应。
- 同一载荷类型的多个通道相遇时，名称必须带来源或目的角色，例如completion mux处的
  `exu_result`和`lsu_writeback`。
- 当前P0从完成到架构状态的路径使用`writeback`；执行单元到ROB/CDB的事件使用
  `completion`；只有顺序架构事件才能使用`commit`。
- 局部信号禁止使用`_i`或`_o`后缀；这些后缀专门保留给模块端口。

P4后的目标源码布局：

```text
riscv32/
  ARCHITECTURE_PLAN.md
  riscv32_pkg.sv
  core/
  frontend/
  backend/
    rename/
    issue/
    execute/
    commit/
  memory/
  privileged/
  sim/
  experiments/
```

`riscv32_ALU_for_sta.sv`和`shl4_for_sta.sv`等仅用于STA的模块必须放在
`experiments/`下，禁止加入CPU filelist。

当前P3B检查点布局：

```text
riscv32/
  common/       共享架构类型和协议类型
  core/         CPU架构状态和执行模块
  system/       CPU封装、仲裁和地址路由
    peripheral/ CPU core外部的可综合AXI外设
  sim/          DPI存储器、仿真UART和仿真器top
  experiments/  独立的STA及运算符映射实验
  filelist/     仿真和可综合core源码清单
  doc/          架构、命名和迁移决策
```

长期维护的模块设计记录和可复现实验日志统一放在`npc/docs/microarchitecture/`。它们刻意
位于RTL源码树之外，因为其内容会跨越多个实施阶段和测量版本，而不是只描述单个源码文件。
RTL TODO仍然必须放在实际插入代码位置的正上方。

P3B的目录拆分有意比最终P4布局更粗。只有frontend、backend、memory和privileged等架构块
具备独立所有权及验证边界后，才引入对应子目录。

## 16. 冻结决策和变更流程

初始冻结决策：

| ID | 决策 |
| --- | --- |
| D001 | IDU是外部译码级边界；decoder lane只是可选内部实现 |
| D002 | 已被D016取代 |
| D003 | OoO设计使用显式物理寄存器重命名 |
| D004 | ROB提供顺序提交和精确异常 |
| D005 | 所有架构副作用均由commit授权 |
| D006 | 通道使用载荷加独立valid/ready信号 |
| D007 | 多宽接口使用数组；各宽度保持为独立参数 |
| D008 | 整数和访存发射队列相互分离 |
| D009 | LSU包含LSQ语义；已提交store通过store buffer排出 |
| D010 | Completion支持多端口，且与commit分离 |
| D011 | 不设置全局Controller，也不保留永久WBU |
| D012 | DPI和仿真器行为必须位于`riscv32_core`之外 |
| D013 | Redirect仲裁集中完成，但redirect检测仍由各来源模块负责 |
| D014 | Trace和DiffTest消费已提交指令记录 |
| D015 | SystemVerilog名称及缩写统一使用小写蛇形命名 |
| D016 | core只实现RV32I，包含32个架构整数寄存器，不提供RV32E模式 |
| D017 | 已被D018取代 |
| D018 | 迁移过程始终保留可运行检查点，每次只推进一个架构边界 |
| D019 | P0使用无存储的类型化valid/ready通道和宽度为1的commit边界 |
| D020 | P2访存等待由IFU/LSU本地事务状态负责，禁止使用全局控制器 |
| D021 | 延迟敏感边界评估同周期旁路，并保留寄存器化停顿回退路径 |
| D022 | IFU和LSU保持为独立master，并共享系统层AXI4-Lite仲裁器 |
| D023 | 可综合core、系统集成和仿真外壳是三个独立边界 |
| D024 | 第一版I-cache为8 KiB、2-way、32字节line、单miss阻塞、分级查找、关键字优先、携带epoch，并在refill adapter以上保持协议无关 |

决策编号：D016
日期：2026-07-16
状态：已接受
问题：D002保留了RV32E配置，迫使译码增加合法性检查，同时维护第二套软件ABI和两套互不
兼容的DiffTest寄存器状态布局。
变更方案：将RV32I作为唯一基础ISA，并从RTL、仿真工具和NPC AM目标中删除所有16寄存器
假设。
依据：长期乱序设计本身就需要完整的架构寄存器命名空间，且选用的NEMU参考模型已经关闭
`CONFIG_RVE`。
备选方案：保留参数化RV32E模式；拒绝原因是它增加验证和接口复杂度，却不服务于选定的
CPU目标。
受影响模块和类型：`riscv32_pkg`、`riscv32_idu`、架构寄存器文件、NPC寄存器查看、
DiffTest状态、AM NPC编译目标和ISA测试。
迁移步骤：把架构寄存器数量/索引宽度设为32/5，删除IDU对`x16-x31`的检查，DiffTest比较
32个GPR，并使用`-march=rv32i_zicsr -mabi=ilp32`编译NPC软件。
验证要求：lint、读写`x16-x31`的RV32I程序、RV32I cpu-tests、SDB寄存器查看，以及与关闭
RVE的NEMU动态库进行DiffTest。
取代：D002

决策编号：D017
日期：2026-07-16
状态：已被取代
问题：兼容载荷和wrapper把旧的单周期EXU-to-LSU-to-WBU拓扑保留在新接口内部，使package
同时携带两套竞争架构，并允许新模块继续依赖废弃控制字段。
变更方案：从规范package中删除legacy载荷类型和别名，然后按路线图顺序，仅针对规范
valid/ready通道和载荷重写模块。
依据：目标架构已经替换集中式译码控制、串行writeback、直接DPI访存和来源专属redirect
端口。保留这些接口不能减少最终工作量，还会阻止接口级约束生效。
备选方案：保留兼容typedef和wrapper直到完整core可编译；拒绝原因是每个兼容消费者都会
延长迁移周期，并使架构漂移难以发现。
受影响模块和类型：`riscv32_pkg`、filelist、IFU、IDU、执行单元、LSU、CSR、redirect、
寄存器文件、core/top、commit、仿真适配器，以及全部旧
`decode_ctrl_t`、`ex_result_t`和`lsu_result_t`消费者。
迁移步骤：冻结规范package类型；重写IFU和IDU；建立core、commit、trap、仿真存储和仿真
debug边界；用专用执行及completion路径替换EXU/LSU/WBU；在后续阶段增加
rename/ROB/issue/LSQ。
验证要求：clean break后的package lint、每个替代模块的模块级lint，以及在P0/P1退出点恢复
集成lint、cpu-tests、trace、DiffTest和RT-Thread。
取代：仅取代兼容迁移TODO，不取代冻结的目标架构决策

决策编号：D018
日期：2026-07-16
状态：已接受
问题：D017在替代core存在前就移除了可运行的单周期实现，并跳过了ysyx从DPI存储、总线/
SoC集成到流水CPU的学习顺序。
变更方案：每个阶段都保留可运行检查点。先清理单周期core的类型化边界，再隔离DPI、增加
简单总线、增加标准SoC总线及外设、构建顺序流水线，最后才增加乱序和多宽机制。
依据：这些迁移分别引入不同的正确性问题：模块所有权、存储协议、总线背压、SoC地址
空间、流水相关、精确OoO恢复和多lane顺序。它们需要独立的验证检查点。
备选方案：继续clean break重写；拒绝原因是无法与可运行基线比较，并会混合互不相关的
故障来源。
受影响模块和类型：路线图、`riscv32_pkg`、filelist、所有当前单周期模块、存储适配器、
总线适配器、SoC top，以及后续流水线/backend模块。
迁移步骤：恢复P0构建；把当前载荷标记为阶段专用；每次完成一个类型化接口；每次修改后
执行完整P0回归；只有满足当前阶段退出标准后才推进。
验证要求：每个检查点执行lint和完整功能回归；从P2开始增加协议断言；从流水线阶段开始
执行综合和STA测量。
取代：D017

决策编号：D019
日期：2026-07-16
状态：已接受
问题：P0 bundle注释把valid/ready推迟到流水线阶段，与D006冲突；同时，分散控制和载荷
内部valid位仍然耦合模块实现细节。
变更方案：P0每个流水边界都使用载荷加独立valid/ready，但不增加流水级寄存器或队列。
背压组合传播到IFU，架构副作用只在宽度为1的末端路径发生fire时产生。
依据：无存储通道保持现有单周期时序，同时为IFU、IDU、执行、LSU、completion和commit
建立明确的生产者-消费者契约。
备选方案：到P4前只使用无握手bundle；拒绝原因是P1/P2访存等待会迫使接口再次完全重写。
现在增加流水级寄存器；拒绝原因是会把ysyx单周期重构和相关处理混在一起。
受影响模块和类型：`fetch_entry_t`、`decoded_uop_t`、`execute_packet_t`、
`execute_result_t`、`writeback_result_t`、`commit_t`、IFU、IDU、EXU、LSU、
completion mux、commit、trap controller、redirect arbiter、CSR file、架构寄存器文件和top。
迁移步骤：删除旧控制/结果载荷；连接无存储通道；以fire控制PC和副作用；到P1前保留DPI
存储；只有后续阶段明确需要时才增加通道存储。
验证要求：lint、build、dummy、RV32I cpu-tests、yield-os、trace和DiffTest。
取代：不取代目标决策；细化D006和D018在P0的实施方式

决策编号：D020
日期：2026-07-16
状态：已接受
问题：ysyx固定延迟SimpleBus练习可能被理解为需要全局CPU状态机。这会耦合无关模块，
并阻碍后续cache及多未完成事务演进。
变更方案：保留规范类型化请求/响应通道。P1先把DPI移至仿真适配器并加入固定一周期完整
握手；P2再用可变延迟和背压验证同一套IFU/LSU本地事务状态。
依据：延迟响应要求请求端保存事务身份，并在背压期间保持下游载荷。该状态属于拥有请求
的端点。未来I-cache/fetch queue及LSQ/cache结构会扩展相同边界。
备选方案：使用一个全局多周期控制器；拒绝原因是它集中访存、执行和redirect策略。
受影响模块和类型：`riscv32_ifu`、`riscv32_lsu`、`riscv32_sim_mem`、
`riscv32_core`、`top`、`imem_req_t`、`imem_resp_t`、`mem_req_t`和`mem_resp_t`。
迁移步骤：完成完整握手端口和本地端点状态；实现固定延迟DPI slave；测试stall和redirect；
然后注入可变延迟。
验证要求：通道稳定性断言、禁止重复请求/store、redirect后丢弃过时取指、随机请求/响应
延迟、P0功能回归、DiffTest，以及由commit驱动的trace/DiffTest时序。
取代：不取代目标决策；澄清D012及P1/P2的存储所有权

决策编号：D021
日期：2026-07-18
状态：已接受
问题：如果每次仲裁都先寄存结果再发出请求，那么即使选中的下游已经就绪，也会固定增加
一个周期。反过来，不受限制地加入组合旁路，又可能形成协议组合环、造成载荷不稳定、拉长
关键路径，或在反压后把事务响应路由给错误的请求端。
变更方案：每个延迟敏感的模块边界都必须显式评估同周期旁路。协议正确性和时序允许时默认
采用旁路，同时保留寄存器状态作为事务受阻后的回退路径。当前AXI4-Lite读仲裁器在
`READ_ARBITRATE`直接转发选中的AR通道；同周期完成AR握手时进入
`READ_WAIT_RESPONSE`，发生阻塞时锁定请求端，并通过`READ_SEND_ADDRESS`继续发送。
本阶段仍只允许一个未完成事务。
依据：AXI要求master在`ARREADY`为低时保持`ARVALID`及AR载荷稳定。因此，快速路径受阻后
锁定请求端可以保持协议正确。选择逻辑不依赖`ARREADY`，从而避免ready到valid组合环。
去掉固定的仲裁寄存周期，可以在不改变顺序和响应路由的前提下，将无竞争读地址延迟减少
一个周期。
备选方案：始终寄存仲裁结果后再转发；拒绝原因是固定增加了可避免的延迟。所有边界都无条件
增加旁路；拒绝原因是时序收敛、恢复、扇出和组合环风险必须逐个边界评估。
受影响模块和类型：`riscv32_axi_lite_arbiter`、后续cache仲裁器、前递网络、发射选择路径、
完成路由以及valid/ready适配器。
迁移步骤：增加AR仲裁快速路径和寄存器化阻塞回退；增加稳定性及单请求端断言；后续延迟敏感
边界沿用同一评估规则；当STA或协议组合证明旁路不安全时，插入寄存器或skid buffer。
验证要求：AXI通道稳定性断言、IFU/LSU同时请求、首个请求周期`ARREADY`分别为高和低、
随机反压、公平性检查、功能回归，以及旁路启用前后的综合/STA对比。
取代：不取代目标决策；细化D006和P3的延迟策略

决策编号：D022
日期：2026-07-18
状态：已接受
问题：IFU和LSU之前分别连接仿真存储器的独立AXI端口，没有覆盖竞争、响应路由和共享外部
slave接口，因此不能作为单端口存储器或SoC互连的检查点。
变更方案：IFU和LSU保留为独立AXI4-Lite master，在系统集成层放置
`riscv32_axi_lite_arbiter`。`riscv32_sim_mem`只暴露一个AXI4-Lite slave端口。IFU和LSU
读请求采用事务级轮询仲裁，只保留一个未完成读事务，并依据锁定的请求端路由响应。LSU独占
的AW/W/B通道直接转发，读写slave状态相互独立。
依据：集成后的拓扑已经通过lint、固定与随机延迟下的load-store测试、load-store DiffTest，
以及固定延迟和随机种子42下的RT-Thread启动。AR同周期快速路径消除了固定仲裁周期，寄存器
回退则在反压时保持AXI稳定性。
备选方案：保留IFU/LSU独立存储端口；拒绝原因是绕过了必须验证的仲裁行为。把仲裁放进IFU
或LSU；拒绝原因是两者都不拥有系统级竞争策略。把读写合并成一个全局状态机；拒绝原因是
AXI读写通道相互独立。
受影响模块和类型：`riscv32_core`、`riscv32_npc_axi_lite`、`top`、
`riscv32_axi_lite_arbiter`、`riscv32_sim_mem`以及`riscv32_pkg`中的AXI4-Lite载荷类型。
迁移步骤：补全协议断言；增加SoC地址选择和真实外设slave；将协议适配移到后续I-cache/
D-cache接口之下；只有实现burst或多个未完成事务时才采用完整AXI4。
验证要求：协议断言、固定/随机延迟回归、IFU/LSU同时发起读请求、AW/W到达顺序测试、
cpu-tests、DiffTest和RT-Thread启动。
取代：不取代目标决策；完成P3A共享slave检查点

决策编号：D023
日期：2026-07-18
状态：已接受
问题：仿真顶层此前同时拥有处理器数据通路、AXI仲裁、DPI存储器和调试钩子，使CPU与仲裁器
无法在不解析仿真专用DPI代码的情况下独立综合或接入SoC。
变更方案：`riscv32_core`只拥有可综合的处理器状态和功能单元连接，并在本检查点暴露独立的
IFU和LSU AXI4-Lite master端口。`riscv32_npc_axi_lite`作为可综合集成边界，通过
`riscv32_axi_lite_arbiter`合并两个端口，并暴露一个面向存储器的AXI4-Lite master接口。
`top`将该边界与`riscv32_sim_mem`连接，并保留仿真专用DPI调试逻辑。
依据：拆分后Verilator lint通过，Slang/Yosys可以在不包含`riscv32_sim_mem`或`top`的情况下
映射`riscv32_npc_axi_lite`。
备选方案：把共享仲裁器放进`riscv32_core`；拒绝原因是系统级竞争不属于处理器功能单元职责。
综合`top`；拒绝原因是它包含DPI和延迟注入行为。
受影响模块和类型：`riscv32_core`、`riscv32_npc_axi_lite`、`top`、仿真及STA filelist，
以及AXI时序约束。
迁移步骤：P3期间保留当前core侧AXI端口；P5在I-cache/D-cache边界以下承接AXI；将DPI调试
和SoC外壳一起迁移到`riscv32_sim_debug`。
验证要求：lint、固定/随机延迟功能回归、DiffTest、RT-Thread启动、映射后综合检查，以及统一
AXI集成边界的STA。
取代：不取代目标决策；落实P1/P3的可综合边界要求

决策编号：D024
日期：2026-07-30
状态：已接受
问题：4字节直接映射练习cache虽能满足最小教学任务，但会固化不合适的前端边界，几乎无法
利用空间局部性，并在流水化或加宽取指前再次要求结构重写。直接实现多MSHR非阻塞cache又会
在首个cache检查点混入过多尚未验证的机制。
变更方案：第一版I-cache冻结为8 KiB、2-way组相联、32字节line、128组、4字节取指宽度和
一个阻塞式miss entry。采用适合同步阵列的S0/S1/S2查找流水、关键字优先refill与提前重启、
无效way优先并辅以每组1位替换状态、用于redirect丢弃的fetch epoch、基于PMA的不可缓存/
不可执行处理，以及显式`fence.i`失效。IFU侧保持协议无关，AXI4-Lite只存在于refill adapter；
本检查点通过8次独立32位读完成一条cache line的refill。
依据：接入cache前的microbench基线在118497980个活跃周期内提交821857条指令，IPC为
0.006936。IFU等待响应占112302555个周期，即94.772%，平均IFU响应延迟为136.645周期，
因此重复取指是第一个由测量证据支持的cache优化目标。Ibex展示了分级查找、关键字优先填充、
失效和旁路；BOOM展示了fetch buffer解耦；香山展示了阵列、流水、miss、替换和控制职责分离。
备选方案：采用手册中的4字节直接映射cache；拒绝原因是它不涉及line refill或组相联，也没有
有效的演进路径。从多MSHR和预取开始；暂缓原因是现在先冻结请求身份和模块边界，非阻塞行为
应在阻塞版本验证并测量后增加。把AXI直接放进IFU或cache命中流水；拒绝原因是下层传输协议
不属于前端策略。
受影响模块和类型：`riscv32_pkg`、`riscv32_ifu`、`riscv32_core`、`riscv32_pmu`、
`riscv32_csr_file`，以及`core/frontend/`下新增的PMA、阵列、refill、miss、cache顶层和
fetch buffer模块。
迁移步骤：完成package类型和PMA；验证阵列；实现refill adapter和一个miss entry；实现
查找、替换和失效；迁移IFU；连接PMU事件；每个模块通过局部编译/单元检查后才加入活动
filelist；完成完整回归并记录性能；之后再评估burst、更多MSHR、预取和更宽取指。
验证要求：参数几何检查、地址边界测试、冷miss/冲突/替换测试、refill顺序及错误注入、随机
反压、每个流水和miss状态下的redirect、`fence.i`、通道稳定性及守恒断言、cpu-tests、
DiffTest、RT-Thread、microbench、综合和STA。
取代：不取代目标决策；细化P5指令cache检查点

如需修改已经冻结的决策，必须追加一份使用以下模板的记录：

```text
决策编号：
日期：
状态：提议中 | 已接受 | 已拒绝 | 已被取代
问题：
变更方案：
依据：
备选方案：
受影响模块和类型：
迁移步骤：
验证要求：
取代：
```

只有决策记录被接受后，才允许增加与原冻结决策冲突的TODO或RTL。决策变化时，必须在同一
次修改中同步更新本计划、邻近RTL TODO、package类型以及模块和文件名称。

## 17. 当前已知偏差

P0-P2类型化通道和P3B ysyxSoC检查点已经具备功能。P5A正在准备I-cache契约和TODO骨架，
未完成的cache源文件不会加入活动filelist。其余差异由后续路线图检查点负责：

| 当前状态 | 后续处理 |
| --- | --- |
| 独立NPC仍使用DPI支持的仿真存储路径 | 保留为快速功能调试环境；ysyxSoC继续作为校准后的集成和性能环境 |
| IFU/LSU直接暴露AXI | P5A/P5：先把IFU迁移到协议无关I-cache通道，再对D-cache采用相同边界原则 |
| I-cache源文件仍为TODO骨架且未加入`filelist.f` | P5A：每个模块通过局部编译和单元检查后再加入，最后启用集成cache |
| 独立`top`仍保留仿真专用DPI调试钩子 | 仿真行为继续位于`riscv32_core`之外；职责模糊时迁移到专用仿真适配器 |
| C++ trace/DiffTest仍采样与P0取指/提交等价的指令 | P1/P4：导出并消费显式`commit_t`事件 |
| EXU仍是聚合模块，completion仍为宽度1的mux | P5：拆分执行单元并增加多端口completion网络 |
| store在P0末端fire时变为可见 | P5/P6：缓存推测store，只允许已提交store排出 |
| CSR合法性检查仍较少，特权级固定为M模式 | P4/P8：增加精确CSR合法性检查和特权级支持 |

必须按照路线图顺序消除这些偏差，禁止在一次未经验证的修改中同时完成全部重命名和结构变化。
