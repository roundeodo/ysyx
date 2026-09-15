# 顺序流水线设计记录

> 历史设计记录：各章节反映不同阶段，早期参数和待办不一定适用于恢复的 RV32 快照。
> 当前配置、实现边界及面试表述见 [RV32 简历核对](../interview/RV32_RESUME_AUDIT.md)。

最后更新：2026-08-25

## 1. 检查点目标

本检查点在不改变ISA、I-cache、LSU语义接口、CSR、commit和DiffTest契约的前提下，把原来
贯穿译码、执行和提交的组合数据通路拆成可反压的顺序流水线。首版优先保证以下性质：

- 指令严格按程序顺序提交；
- 任意反压下都不丢失、不重复、不修改payload；
- RAW、结构和控制冒险均有明确处理；
- trap、`mret`和`fence.i`仍在commit边界恢复，保持精确架构状态；
- DiffTest只观察commit事件，不观察流水级内部的推测状态。

当前检查点已经实现EX/WB到ID/EX的标量操作数forwarding、IFU到IDU之间的两项fetch
queue，以及16项两位饱和计数器BHT和直接跳转预译码。尚未实现非阻塞LSU、D-cache、
多发射或乱序执行。这些功能必须建立在当前正确性边界之上逐项加入，不能通过第二套译码
或第二套架构寄存器状态绕开现有契约。

## 2. 当前数据通路

```text
I-cache/IFU ready-valid保持
          |
          v
  fetch queue（2项已完成取指结果）
          |
          v
      IDU组合译码 + 架构寄存器组合读 + CSR组合读
          |
          v
  decode_execute_stage（ID/EX弹性寄存器）
          |
          v
       EXU或blocking LSU
          |
          v
       completion_mux
          |
          v
  writeback_stage（completion/WB弹性寄存器）
          |
          v
       commit + GPR/CSR架构状态更新 + DiffTest
```

IFU和I-cache使用valid/ready保持当前取指响应；两项fetch queue保存已经完成但IDU尚未接收
的取指结果，用于吸收短时后端反压并切断I-cache到IDU的组合反压路径。IDU是组合译码边界，
`decode_execute_stage`保存进入执行级的指令。

| 边界 | 保存的payload | 有效状态所有者 | 主要作用 |
| --- | --- | --- | --- |
| IFU到fetch queue | `fetch_entry_t` | IFU/I-cache | 交付已经完成的取指结果 |
| fetch queue到IDU | `fetch_entry_t[2]` | `riscv32_fetch_buffer` | 保持PC、指令、前端身份和取指异常 |
| ID/EX | `execute_packet_t` | `riscv32_decode_execute_stage` | 保存uop、两个源操作数和CSR读取结果 |
| EX/LSU完成 | `writeback_result_t` | completion生产者 | 统一标量执行与访存完成结果 |
| completion/WB | `writeback_result_t` | `riscv32_writeback_stage` | 切断执行到commit的组合路径，稳定退休payload |
| commit | `commit_t` | `riscv32_commit` | 唯一架构事件和DiffTest观察点 |

两个流水寄存器都满足同一弹性条件：

```text
stage_can_accept = !stage_valid || downstream_ready
input_ready      = stage_can_accept && !flush
```

当`stage_valid=1`且`downstream_ready=0`时，valid和payload必须保持不变。payload本身不复位，
只有valid位复位；valid为0时payload没有语义，这可以避免宽payload复位网络。

### 2.1 IFU同周期请求换手

I-cache命中响应被IDU接收的同一周期，IFU直接在lookup请求通道呈现下一条顺序PC。若
I-cache的`ready`为1，旧响应离开和新请求进入在同一周期完成，IFU继续保持一个lookup在途；
若`ready`为0，IFU在下一周期进入发送状态并稳定保持相同的PC、前端tag和epoch。该路径消除
了原来每次响应后固定回到发送状态造成的一周期空泡。随后加入的两项fetch queue允许IFU在
IDU短暂停顿时继续交付最多两个已取回结果；队列满后必须向IFU传播反压。

redirect优先于顺序请求。redirect与响应交付同拍发生时，IFU禁止发送旧控制流的`PC+4`，
保存redirect目标并增加epoch；已经发出的旧请求仍完成协议握手，但旧epoch响应只会被排空，
不会进入IDU。取指结果进入fetch queue之前经过控制流预测器：条件分支查16项两位饱和
计数器BHT，`jal`静态预测taken，`jalr`等待EX解析。预测redirect只在对应取指结果真正入队
时发出，避免反压期间对同一条指令重复redirect。EX完成条件分支时训练BHT；EX发现方向错误
时仍通过原有恢复redirect冲刷错误路径。当前结构仍限制为一个lookup在途，不具备多请求并行
或hit-under-miss；这些功能需要显式request queue和返回匹配，不能继续扩展当前两状态FSM。
有限深度队列不能保证后端任意长停顿时仍每拍取指；当前能够保证的是：I-cache本地命中、
lookup端口ready、无redirect且fetch queue有空间时，前端可以连续每拍交付一条指令。

当前预测器只预测PC相对的branch和`jal`，因此流水payload只保存`predicted_taken`，EX根据
branch target或顺序PC重建预测next PC，不携带32位动态target。这一约束为课程配置节省
946.960 um^2。未来加入BTB或预测`jalr`时，target必须重新成为逐指令预测元数据，不能继续
从立即数重建。

在RV32、64B/2-way/8B line课程面积配置下做同代码基线A/B综合：严格串行IFU面积为
25372.676 um^2，同周期换手后为25627.770 um^2，增加255.094 um^2（1.01%）；两者时序
单元面积均为11747.890 um^2，说明代价来自组合控制和选择逻辑，没有增加状态存储。两者均
通过300MHz约束，当前关键路径仍位于后端`execute_packet`寄存器输入。完整流水线core目前
超过25000 um^2课程限制2.51%，需要后续针对全核流水寄存器和控制逻辑继续优化。

## 3. 冒险处理

### 3.1 RAW数据冒险

IDU给出的`uses_rs1/uses_rs2/writes_rd`是冒险判断的唯一语义来源。hazard controller分别
检查EX和WB生产者；EX结果已产生时直接前递，WB结果在提交当拍前递。若最新的EX生产者命中
但结果尚不可用，消费者必须停顿，不能错误使用同名的更旧WB值。load结果在blocking LSU
返回前不可用，因此load-use仍保留RAW停顿。

不检查WAR和WAW：单发射、顺序执行、顺序提交以及架构寄存器只在commit写入，使年轻指令
不可能先于老指令更新架构状态。进入乱序阶段后，这些依赖由rename、物理寄存器和ROB处理。

### 3.2 结构冒险

当前LSU只能保存一个在途事务。`lsu_transaction_active_o`直接表示LSU状态机不在idle；busy
期间阻止年轻指令进入和执行，避免EXU结果与LSU结果争用单一completion口，也避免在没有
load queue的情况下遗失load目的寄存器身份。

### 3.3 串行化指令

CSR、system和其他标记为`serializing`的指令必须等待更老的ID/EX、WB和LSU工作全部排空后
才能进入。它进入后又阻止年轻指令越过，直到自身提交。这保证CSR读取、trap、`mret`和
`fence.i`看到按程序顺序形成的架构状态。

## 4. 控制冒险和flush范围

当前前端使用16项BHT预测条件分支，并静态预测`jal` taken；`jalr`仍在EXU完成握手时解析。
预测正确时不发生流水线flush，预测错误时由EXU发出恢复redirect。redirect来源决定flush范围：

| redirect来源 | redirect指令所在位置 | 必须清除 | 必须保留 |
| --- | --- | --- | --- |
| EXU分支/跳转 | ID/EX输出 | ID/EX中同拍以后可能保存的年轻指令和前端旧epoch响应 | 产生redirect的分支自身及更老WB指令 |
| commit trap/`mret` | WB/commit | ID/EX、同拍到达WB的年轻completion和前端旧epoch响应 | 当前正在提交的老指令 |
| commit `fence.i` | WB/commit | 与commit恢复相同，并启动I-cache失效 | `fence.i`本身 |

IFU在redirect时增加`fetch_epoch`。已经发出的旧取指事务仍必须完成底层握手，但返回的旧epoch
响应不能再次交给IDU。流水级flush负责后端年轻指令，epoch负责前端过期响应，两者不能互相
替代。

## 5. 精确状态和DiffTest

`riscv32_writeback_stage`之后才进入commit。GPR写入、CSR写入、trap和DiffTest比较均由同一
commit事件驱动，因此流水级中的指令尚未成为架构状态。寄存器堆在commit上升沿直接写入，
保证仿真器观察到退休事件时GPR已经更新，不能再额外延迟半个周期。

异常指令可以到达commit，但不会作为普通指令退休；trap controller在commit边界更新CSR并
发出redirect。提交级redirect会阻止同拍年轻EX结果进入WB，这是精确异常成立的关键条件。

### 5.1 同步异常的产生、传递和仲裁

异常元数据随指令一起通过`fetch_entry_t`、`decoded_uop_t`和`writeback_result_t`传递，字段为
`exception_valid`、`exception_cause`和`exception_tval`。流水级不使用独立的全局异常线，
因此反压不会让异常和所属指令错位，flush也会连同年轻指令的异常元数据一起删除。

当前各级产生的同步异常如下：

| 产生位置 | 当前产生的异常 | `tval` |
| --- | --- | --- |
| IFU/I-cache | instruction access fault | 故障取指地址 |
| IDU | illegal instruction、breakpoint、M-mode ecall | 非法指令编码或0 |
| EXU | taken branch/jump target misaligned、illegal CSR access | 目标地址或指令编码 |
| LSU | load/store address misaligned、load/store access fault | 有效地址 |

没有MMU时不会产生instruction/load/store page fault；package保留cause 12、13和15，供未来
TLB/PTW接入。当前只实现M-mode，因此ECALL只产生cause 11；cause 8和9保留给未来U/S-mode。
未实现A扩展，所以表中的Store/AMO异常在当前核中只覆盖store，AMO编码仍按非法指令处理。

同一条指令可能被多个阶段检查，必须保留最早发现的异常。例如IFU已经报告access fault后，
IDU不能再根据无效返回位型把它覆盖成ECALL或illegal instruction；EXU和LSU也只在尚无异常
时生成本级cause。异常完成包在各执行单元出口统一清除GPR写、CSR写、redirect和访存请求等
正常副作用。

不同指令可能在同一拍分别于IFU、IDU、EXU/LSU和WB携带异常。当前单发射顺序流水线不需要
按cause号仲裁：WB中的指令年龄最大，只有它能进入commit；它产生的commit redirect禁止年轻
EX指令发出completion或访存请求，并清空ID/EX、completion/WB以及前端旧epoch响应。因此
最终写入`mepc/mcause/mtval`的一定是程序顺序中最老的异常。

未来乱序实现不能继续依赖流水级位置表达年龄。执行单元只把异常写入ROB项，不立即更新CSR；
只有ROB头部异常才能提交trap。store必须先进入store queue，并在对应ROB项提交后才允许对外
可见，否则年轻store可能在更老异常确定前破坏精确状态。

## 6. 当前性能限制与演进顺序

当前保守规则仍会产生可观停顿，但每一种停顿都有单独PMU计数：RAW等待、串行化等待、LSU
结构等待、控制flush和被提交级恢复丢弃的EX指令。后续优化按以下顺序进行：

1. 已增加EX/WB到ID/EX操作数的forwarding，普通ALU依赖不再固定等待commit；
2. 已增加两项fetch queue，隔离短时IDU反压；
3. 已增加16项BHT和直接跳转预译码，用前端tag和epoch完成错误路径恢复；
4. 已让uncached AXI master在idle首拍直接发出AR或AW/W，删除每次访存固定的一拍空泡；
5. 对load-use保留必要停顿，并在加入D-cache后根据真实返回时刻唤醒；
6. 把blocking LSU升级为D-cache、store buffer和有序完成接口，再考虑多个在途事务；
7. 只有顺序流水线的精确异常和回归稳定后，才引入rename、ROB和乱序调度。

性能计数必须使用互斥优先级归因，不能把IFU response-wait或downstream-backpressure等通道
占用周期直接相加，这些占用可与LSU阻塞重叠。最新平衡配置使用256 B direct-map I-cache和
256 B/2-way阻塞式D-cache。MicroBench中互斥停顿约为：LSU结构31.8%、前端27.6%、控制
恢复9.0%、RAW 1.1%。因此当前已经不是单一瓶颈：D-cache显著降低数据等待后，前端吞吐和
控制恢复重新暴露出来。

流水级寄存器的存在不等于能够达到1 GHz。当前标准单元STA中，无D-cache配置的关键路径
穿过I-cache命中响应、控制流预测、下一PC选择和下一次array读地址，约1.788 ns；加入
256 B/2-way D-cache后的初次最紧路径从EX级经过LSU请求形成、PMA和路由选择穿到data AXI
输出。删除请求首拍不会使用的AXI组合选择后，报告频率从498.001 MHz提高到524.833 MHz，
而IPC保持0.334515；新的最差路径从EX/LSU进入D-cache同步data array读寄存器，数据到达
时间为1.870 ns。1 GHz要求组合路径接近1 ns且还要保留setup、skew和不确定度余量，因此
必须按这些具体路径重新划分流水，而不是只统计模块之间是否已经存在寄存器。

不能只在I-cache响应后盲目增加一级寄存器：当前IFU只有一个lookup在途，这会使请求吞吐降为
约每两拍一条。正确方案是请求侧next-line prediction、多个带tag/epoch的在途lookup、选择性
squash和弹性响应级一起实现。D-cache侧不能只在输入前增加固定延迟寄存器，而要把AGU、
PMA/route和array lookup切成可连续接收请求的流水边界，并用store buffer解除store提交后的
长等待；最终把tag/data array映射为SRAM宏。这些变化保持现有语义请求和AXI协议边界，不把
总线细节重新塞回IFU/LSU。

本轮结构取舍参考以下公开设计，但只采用经过本核A/B数据支持的部分：

- ysyx B5要求先区分指令供给、数据供给和冒险阻塞，再量化优化收益；
- Ibex使用带feedthrough的prefetch FIFO，并在I-cache miss时提前转发critical word；
- CV32E40P使用小型prefetch buffer吸收前端延迟，普通ALU结果支持前递，load-use仍需等待；
- CVA6前端把BHT、BTB预测结果作为逐指令元数据传递，并在后端解析后恢复。

对应到当前核：两项fetch queue和EX/WB forwarding已经实现；16项BHT经过A/B后保留；动态
target、64项BHT和更深I-cache命中流水线因面积或收益证据不足暂不采用。开源项目的模块名称
和参数不能直接替代本核计数器、时序和面积数据。

## 7. 验证

定向测试：

```sh
make test-pipeline-configs PROJECT=riscv32
```

覆盖空级接收、同拍替换、反压payload保持、flush、EX/WB RAW、串行化、LSU结构冒险以及
EX级和commit级redirect的不同清除范围。异常定向场景还覆盖IFU异常优先于IDU重新译码、
EBREAK/ECALL译码、LSU未对齐与访问错误，以及WB、EX和ID同时出现异常时只提交最老异常。

流水线控制的有界形式验证：

```sh
make formal-pipeline
```

当前BMC深度为20。fetch queue使用独立顺序参考模型验证不丢失、不重复、保持顺序、flush
清空和反压稳定；hazard controller验证EX/WB最新生产者优先、不可用结果必须停顿、同一源
操作数不会同时选择两个前递源。该验证只覆盖控制模块性质，不等价于整核形式化证明。

整机回归：

```sh
make regression-p3-f-rv32 PROJECT=riscv32
make regression-p3-f-rv64 PROJECT=riscv32
```

MicroBench用于比较流水化前后的周期、IPC和各类停顿占比，不能只比较宿主机仿真耗时。

2026-08-24验证结果：RV32和RV64各35项CPU/异常DiffTest全部通过；RV32 MicroBench
`test`通过。首版串行IFU的PMU窗口执行2157726周期、IPC为0.199377；加入同周期请求换手后，
同一测量窗口执行1971267周期、IPC为0.218236，周期减少186459（8.64%），IPC提升9.46%。
该优化不增加在途请求数或存储项，只删除固定前端空泡。

加入两项fetch queue和EX/WB forwarding后，同一MicroBench `test`测量窗口执行1770976周期、
退休430203条指令，IPC为0.242918；相对同周期换手版本减少200291周期（-10.16%），IPC提升
11.31%。完整运行中RAW等待为255742周期，LSU结构等待为1438484周期，控制flush为178314次，
IFU下游反压占50.252%。当前最大瓶颈已经是blocking LSU；队列不能消除持续后端停顿，下一步
应优先缩短数据访问占用，再加入分支预测减少错误路径取指。

2026-08-25在相同1KiB/2-way/8B line I-cache和MicroBench `test`下逐项优化：16项BHT和
`jal`预译码把PMU窗口从1770976周期降至1593126周期，IPC从0.242918升至0.270037；再加入
uncached AXI idle首拍直通后降至1513766周期，IPC升至0.284193，计分时间为15.261 ms。
完整运行的互斥空发射槽归因为：LSU结构阻塞47.943%、控制恢复9.033%、前端供给9.709%、
未解决RAW 1.440%。I-cache命中率99.062%、命中延迟1拍、AMAT 1.260拍。由此确定下一项主要
性能工程是D-cache和有序访存解耦，而不是继续增加fetch queue或盲目加深I-cache命中流水线。

在64B/2-way/8B line课程面积配置下，加入压缩预测元数据后的core面积为27375.656 um^2；
uncached AXI idle首拍直通后为27541.640 um^2，增加165.984 um^2。300MHz约束下TNS为0，
报告中最紧的core输出路径约431.896MHz。该直通路径带来约4.9%的MicroBench计分时间收益，
但也把AXI输出边界推成时序关注点；后续若提高目标频率，应在保持请求零空泡的前提下使用
skid buffer或重新切分总线边界，而不是恢复固定首拍空泡。

## 8. RV32基线的低面积结构优化与否决标准

2026-08-26对`rv32-baseline`执行同配置A/B。当前保留的改动包括：LSU完成拍允许下一请求
进入、fetch buffer的ready解耦、D-cache接收窗口预读阵列、删除数据子系统重复请求队列，
以及把BHT训练反馈切成寄存路径。这些改动不增加cache容量，也不改变IFU、LSU语义请求或
AXI4协议；最终NanGate45结果为69295.394 um^2、797.945 MHz。完整MicroBench `train`
基线计分窗口退休186810217条指令，执行492988655周期，IPC为0.378934，Scored time为
4929.979 ms；全程互斥停顿中前端占28.159%，LSU结构占20.817%，控制恢复占8.277%。

随后评估单MSHR下的“不同set hit-under-miss”：refill存续期间允许不同set进入lookup，
若命中则直接返回，若未命中则在S1等待MSHR释放；同set冲突继续阻塞。该方案不增加第二个
MSHR，但给请求ready路径增加active-refill set比较。完整`train`只把计分窗口周期降到
492654221，减少334434周期，即0.068%；Scored time从4929.979 ms降到4926.640 ms。
与此同时，面积增至69549.424 um^2（+0.37%），Fmax降至767.625 MHz（-3.80%），
`IPC * Fmax`从302.368降到291.076 MIPS（-3.73%）。因此该方案已经从RTL中删除。

保留的refill优化仅限同一line中已经到达的word early restart。它直接复用refill写入的
victim way，不增加set级hit-under-miss控制。后续若要真正解除I-cache miss阻塞，应使用
明确的lookup队列、多个MSHR、返回标识和array端口仲裁，并重新评估面积、周期和关键路径；
不能继续把更多比较器叠加到单MSHR的请求ready路径上。

D-cache data array还尝试过“通用多维数组+byte strobe+低电平透明写锁存”。功能测试可以
通过，但Yosys为动态way/word/byte局部写展开了大量process mux，综合规模失控，因此也已
撤销。若以后用锁存阵列降低面积，必须按way、word和byte静态分bank，或直接推断/实例化
目标工艺SRAM宏，不能依赖通用动态索引局部写综合出合理存储结构。

### 8.1 请求解耦不能只增加反馈旁路

在相同`rv32-baseline`、MicroBench `test`和NanGate45 1 GHz约束下，PMA的三种等价表达、
数据请求直通加一项skid、禁用LSU响应拍滚动接收都没有形成可保留的收益。所有候选的
`test`周期都与1194972周期基线相同；但数据请求skid使Fmax从766.875降到724.426 MHz，
max TNS从-457.502恶化到-1500.110。它在空闲时组合直通请求，并把pending状态反馈到
上游ready，实际增加了跨层级反馈而不是形成流水边界。

禁用LSU滚动接收仅减少6.118 um^2，Fmax反而降至748.921 MHz，最慢路径转移到D-cache
预读data array输入。这说明物理优化不能只盯住当前报告中的第一条路径：LSU状态、路由
选择、D-cache预读和前端next-PC是彼此接近的路径组，删除其中一条后另一条会立刻成为
限制。

响应侧控制流预译码的A/B也验证了相同原则。删除它后Fmax升至786.214 MHz、面积下降
0.850%，但`test`周期增加1.999%，`IPC * Fmax`只改善0.513%，max TNS反而恶化28.229%。
该逻辑能在BTB冷失配时早于EX纠正JAL、条件分支和标准ret，不能仅因它接近关键路径就删掉。

后续真正的边界必须同时满足：

1. 用寄存请求项或队列切断下游`ready`到上游状态的长反馈；
2. 保存PC、预测、epoch、访存属性和返回身份，使请求与响应可以跨周期关联；
3. 允许旧响应离开与新请求进入并行发生，不能用固定空泡换频率；
4. 若只有一个在途上下文无法维持吞吐，应增加有限队列、store buffer或多个请求上下文，
   再用周期、面积、Fmax和TNS共同决定是否保留。

因此，skid buffer、流水寄存器和队列不是按名称判断是否“高性能”，而是看它是否真正切断
反馈、是否保留吞吐、是否有足够上下文覆盖新增延迟，以及综合后是否改善整个路径组。

### 8.2 架构响应与cache物理事务必须分离

D-cache曾实验在load miss收到请求word后立即向LSU返回数据。该方向在语义上可行，但要求
同时维护两种不同的生命周期：

1. 架构响应生命周期：请求指令何时获得load数据并可继续执行；
2. 物理事务生命周期：脏行写回、剩余refill beat、line install和AXI响应何时全部完成。

架构响应完成后，物理事务仍可能占用AXI读写通道。数据路由不能在前者完成时回到idle，
否则新请求可能切走响应通道，使当前refill停在中间。成熟的非阻塞cache由MSHR保存refill
状态，由writeback queue保存被驱逐脏行，pipeline/ROB只消费架构响应；三者通过事务标识
关联，而不是共用一个`done`状态。

当前阻塞式D-cache的提前响应实验在MicroBench `test`仅减少0.768%测量周期，却增加
1.34%面积并使Fmax下降2.15%，`IPC * Fmax`下降1.40%。主要原因是66.290%的miss包含脏
victim，且store不能使用load的提前响应路径。因此当前版本仍在完整line事务结束后响应；
未来加入MSHR和writeback queue时再实现critical-load-first，避免为阻塞式控制增加一套
低利用率的事务保持网络。

### 8.3 面积口径与1 GHz路径边界

当前STA顶层是`riscv32_core`。filelist中位于core顶层之外的CLINT、系统地址路由器、SoC
位宽转换器和仿真顶层不会因“出现在filelist”就计入面积；Yosys只保留从`riscv32_core`
可达的实例。`NPC_ENABLE_SIM_MONITOR`也没有在STA filelist中定义，因此I-cache/D-cache
分析计数器和`$display`监视逻辑不参与综合。

必须计入真实core面积的结构包括：流水级payload寄存器、hazard/forwarding控制、redirect
恢复、fetch buffer、分支预测器、cache、架构寄存器、异常所需CSR和软件可见的架构计数器。
纯`typedef/struct`、未实例化模块和仿真监视器本身不产生面积。不能因为某个流水边界未来可
扩展为乱序接口，就把当前已经参与功能的寄存器或控制逻辑从core面积中扣除。

基线总面积69448.610 um^2中，CSR约1844.178 um^2，只占约2.66%；删除CSR或PMU不能解决
主要面积问题，也不能改善当前最慢路径。面积主要来自用标准单元实现的I/D cache阵列、32项
架构寄存器和预测表，其中综合报告含6790个DFF_X1与2048个DLH_X1。后续可同时维护“课程
最小配置”和“完整架构配置”两个真实可综合配置，但每个配置都必须按实际实例统计，不能在
同一网表上主观扣除模块。

达到1 GHz的下一步不是继续删除低占比CSR，而是把当前1.257 ns的EX/LSU组合路径切开。
推荐边界为`ID/EX -> AGU/EX -> EX/MEM弹性寄存项 -> LSU/cache lookup -> MEM/WB`。
新增边界会使每条访存至少增加一拍，因此必须同时支持每拍接收新请求，并在后续通过store
buffer或有限在途上下文覆盖延迟；完成后重新测量IPC、Fmax、面积和TNS，再决定是否保留。

## 2026-09-06：面积与 train IPC 实验中的流水边界

当前实验候选移除了独立译码寄存级，结构为：取指队列 → 组合译码/GPR 读取 →
寄存器读级 → ID/EX → EX。普通指令经过 EX 结果寄存器，访存由 LSU 交付，随后统一
进入 WB/commit。保留 EX 结果和前端重定向寄存边界，不以固定“六级流水”描述这些实现细节。

LSU 成功交付 WB 的同拍，允许独立普通指令进入空 EX 结果级；它最早下一拍进入 WB。
访存尚未完成或发生异常时保持阻塞，load 依赖仍等待 WB 前递。这没有增加多发射、
乱序提交或新的退休队列。当前 test、完整 train 与 820 MHz STA 已通过；同环境 train IPC 比本轮基线提高 2.69%。
见 [实验设计](RV32_HARDWARE_OPTIMIZATION_DESIGN_RECORD.md) 与
[测量记录](../verification/RV32_HARDWARE_OPTIMIZATION_2026-09-06.md)。
