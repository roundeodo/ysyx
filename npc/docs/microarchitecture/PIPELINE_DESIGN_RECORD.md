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

首版不实现forwarding、分支预测、非阻塞LSU、多发射或乱序执行。这些功能必须建立在当前
正确性边界之上逐项加入，不能通过第二套译码或第二套架构寄存器状态绕开现有契约。

## 2. 当前数据通路

```text
I-cache/IFU ready-valid保持
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

IFU和I-cache已经使用valid/ready保持尚未消费的取指响应，因此首版没有复制一个功能相同的
IF/ID寄存器。IDU是组合译码边界，`decode_execute_stage`是第一处新增的流水寄存器。

| 边界 | 保存的payload | 有效状态所有者 | 主要作用 |
| --- | --- | --- | --- |
| IFU到IDU | `fetch_entry_t` | IFU/I-cache | 保持PC、指令、前端身份和取指异常 |
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

## 3. 冒险处理

### 3.1 RAW数据冒险

IDU给出的`uses_rs1/uses_rs2/writes_rd`是冒险判断的唯一语义来源。当前没有forwarding，若
ID/EX或WB中的老指令将写入当前译码指令使用的源寄存器，hazard controller阻止当前指令
进入ID/EX。生产者在commit边沿写入架构寄存器后，下一周期消费者从组合读口读到新值。

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

## 6. 当前性能限制与演进顺序

首版的保守规则会产生可观停顿，但每一种停顿都有单独PMU计数：RAW等待、串行化等待、LSU
结构等待、控制flush和被提交级恢复丢弃的EX指令。后续优化按以下顺序进行：

1. 增加EX/WB到ID/EX操作数的forwarding，缩短普通ALU RAW等待；
2. 对load-use保留必要停顿，并在加入D-cache后根据真实返回时刻唤醒；
3. 增加静态或动态分支预测，用前端tag和epoch完成错误路径恢复；
4. 把blocking LSU升级为带队列的接口，再考虑独立completion仲裁；
5. 只有顺序流水线的精确异常和回归稳定后，才引入rename、ROB和乱序调度。

## 7. 验证

定向测试：

```sh
make test-pipeline-configs PROJECT=riscv32
```

覆盖空级接收、同拍替换、反压payload保持、flush、EX/WB RAW、串行化、LSU结构冒险以及
EX级和commit级redirect的不同清除范围。

整机回归：

```sh
make regression-p3-f-rv32 PROJECT=riscv32
make regression-p3-f-rv64 PROJECT=riscv32
```

MicroBench用于比较流水化前后的周期、IPC和各类停顿占比，不能只比较宿主机仿真耗时。
