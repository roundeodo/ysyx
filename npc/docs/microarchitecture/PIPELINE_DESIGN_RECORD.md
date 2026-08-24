# 顺序流水线设计记录

最后更新：2026-08-24

## 1. 检查点目标

本检查点在不改变ISA、I-cache、LSU语义接口、CSR、commit和DiffTest契约的前提下，把原来
贯穿译码、执行和提交的组合数据通路拆成可反压的顺序流水线。首版优先保证以下性质：

- 指令严格按程序顺序提交；
- 任意反压下都不丢失、不重复、不修改payload；
- RAW、结构和控制冒险均有明确处理；
- trap、`mret`和`fence.i`仍在commit边界恢复，保持精确架构状态；
- DiffTest只观察commit事件，不观察流水级内部的推测状态。

当前检查点已经实现EX/WB到ID/EX的标量操作数forwarding，以及IFU到IDU之间的两项
fetch queue；尚未实现分支预测、非阻塞LSU、多发射或乱序执行。这些功能必须建立在当前
正确性边界之上逐项加入，不能通过第二套译码或第二套架构寄存器状态绕开现有契约。

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
不会进入IDU。当前结构仍限制为一个lookup在途，不具备多请求并行、hit-under-miss或预测
取指能力，这些功能需要显式request queue和返回匹配，不能继续扩展当前两状态FSM实现。
有限深度队列不能保证后端任意长停顿时仍每拍取指；当前能够保证的是：I-cache本地命中、
lookup端口ready、无redirect且fetch queue有空间时，前端可以连续每拍交付一条指令。

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

当前前端按顺序PC取指，没有方向预测；taken branch、`jal`和`jalr`在EXU完成握手时产生
redirect。redirect来源决定flush范围：

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
3. 对load-use保留必要停顿，并在加入D-cache后根据真实返回时刻唤醒；
4. 增加静态或动态分支预测，用前端tag和epoch完成错误路径恢复；
5. 把blocking LSU升级为带队列的接口，再考虑独立completion仲裁；
6. 只有顺序流水线的精确异常和回归稳定后，才引入rename、ROB和乱序调度。

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
