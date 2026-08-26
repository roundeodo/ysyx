# RV64 顺序流水线设计记录

状态：当前实现

## 1. 设计目标

当前流水线是从多周期顺序核向乱序核过渡的可验证基线。它必须做到：

- 单发射、顺序完成和精确提交；
- 每个流水边界使用valid/ready，允许独立反压；
- 普通整数相关通过前递连续发射；
- load、串行化指令和结构冲突只阻塞真正受影响的指令；
- 分支错误、异常、`mret`和`fence.i`能够清除所有年轻指令；
- 仿真性能事件不进入综合core。

## 2. 数据通路

```text
predictor -> IFU/I-cache -> fetch buffer
         -> IDU -> decode stage
         -> register read stage
         -> ID/EX stage -> EXU
         -> execute result stage
         -> completion/writeback stage
         -> commit
```

load/store在EXU生成`lsu_req_t`后进入LSU和数据存储子系统。它们可能经历D-cache命中、
cache miss、writeback或uncached AXI事务，因此不是固定延迟执行单元。

## 3. 流水边界

### 3.1 fetch buffer

保存已经返回的`fetch_entry_t`，把I-cache响应与译码反压分离。redirect通过flush清除错误
路径entry；IFU的epoch同时负责丢弃已经发出但已经过期的取指响应。

### 3.2 decode stage

锁存`decoded_uop_t`。译码只生成微操作和控制字段，不读取寄存器，也不产生架构副作用。

### 3.3 register read stage

读取GPR并保存原始操作数。若同一拍WB写入与读取同一寄存器，显式WB旁路保证保存新值。

### 3.4 ID/EX stage

在进入该级前完成操作数选择和前递。`execute_packet_t`同时携带uop、源操作数和CSR读取
结果。普通整数生产者可以从EX、execute-result或WB级前递；load值只有在数据返回并进入
WB边界后才可前递。

### 3.5 execute result stage

保存EXU结果，并在寄存边界后解析控制流。这样分支恢复逻辑不会和当前ALU、前递mux以及
前端请求组合成一条长路径。

### 3.6 writeback与commit

completion mux在普通EXU结果和可变延迟LSU结果之间选择。writeback stage保存完成结果。
commit是GPR、CSR、trap、`mret`和性能退休事件的唯一权威边界。

## 4. 冒险处理

`riscv32_pipeline_hazard_controller`比较消费者的`rs1/rs2`与各在途生产者：

- EX普通整数结果可从`exu_result`前递；
- execute-result级结果可从`resolved_execute_result`前递；
- WB结果可从`writeback_result`前递；
- load结果尚未返回时产生RAW阻塞；
- CSR、trap相关操作和`fence.i`使用serializing语义；
- LSU存在未完成事务时，不允许年轻指令越过它产生副作用。

同一寄存器存在多个老生产者时，年龄最近的生产者优先。若最近结果尚不可用，不能错误地
采用更老的WB值。

## 5. 控制恢复与异常

执行级分支错误最早由execute-result级发现。恢复分为两步：

1. 发现错误的同拍阻止年轻指令issue，并清除后端年轻valid；
2. redirect经过专用寄存器后交给IFU，前端更新epoch并清空fetch buffer。

异常沿uop向后传播，不在最早发现处立即修改CSR。只有异常指令到达commit时，trap
controller才写`mepc/mcause/mtval`并重定向到`mtvec`。因此多个级同时报告异常时，顺序
提交天然选择最老指令，年轻异常随flush失效。

## 6. 正确性不变量

- `valid && !ready`期间payload保持稳定；
- flush只清valid，不伪造ready握手；
- 每条被接收的指令至多提交一次；
- 错误路径指令不能写GPR、CSR或内存；
- 未解决RAW不能进入EX；
- 同一源操作数至多选择一个前递来源；
- 串行化指令提交前，年轻指令不能产生架构副作用。

这些不变量由RTL断言和`tests/formal`中的有界检查持续验证。

## 7. 向乱序执行演进

当前stage payload、精确commit、执行完成接口和前端epoch可以复用。以下结构不会直接扩展：

- 集中式hazard controller将被rename、issue queue和ROB替代；
- 架构寄存器号RAW比较将被物理寄存器依赖替代；
- completion mux将演进为带tag的结果网络；
- 单个LSU事务状态将演进为LSQ和store commit；
- 全流水flush将演进为分支checkpoint和选择性恢复。

