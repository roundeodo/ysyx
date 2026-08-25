# D-cache微架构设计记录

状态：首版阻塞式检查点已实现

最后更新：2026-08-25

## 1. 目标与边界

本检查点解决顺序流水线中每条普通load/store都直接等待外部存储器的问题，同时冻结能继续
演进到高性能AI CPU的模块边界。LSU只产生`data_memory_req_t`语义请求，不处理cache tag、
替换或AXI状态；PMA先决定访问权限和cacheability；D-cache负责普通内存；uncached master
负责MMIO和低延迟片上存储；二者在数据子系统中合并成一个AXI manager。

默认配置为1 KiB、2-way、32 B cache line、write-back、write-allocate和单MSHR。它是用于
建立正确性、协议和验证闭环的第一版，不是最终AI产品配置。

## 2. 当前数据路径

1. `riscv32_data_memory_subsystem`用PMA检查`readable/writable/cacheable`。
2. cacheable请求进入D-cache；MMIO、MROM和片上SRAM请求进入uncached master；权限失败在
   本地形成access fault。请求握手后路由选择一直锁定到响应握手。
3. D-cache S0在请求握手时同时发起同步tag/data array读取；S1保存请求，下一拍比较所有way。
4. load hit返回命中word；store hit只在响应握手时按byte strobe更新data array并置dirty，
   因此上游反压不会重复写入。
5. miss先使用invalid way，否则使用每set round-robin选择的way。dirty victim先逐word读出并
   组成line，再通过AXI burst写回；随后通过AXI burst refill。每个返回beat立即写data array，
   最后一个beat成功后才写入新tag/present/dirty元数据并向LSU返回。
6. `fence.i`先要求D-cache clean所有dirty line，再使I-cache失效，最后redirect。这个顺序确保
   自修改代码先进入下层统一存储，再允许取指侧重新填充。

## 3. 共享SRAM与AXI仲裁

I-cache和数据子系统各自拥有一个完整AXI manager。`riscv32_axi4_core_merge`是当前共享内存
入口的仲裁点：

- AW/W/B只来自数据侧；
- AR空闲时在指令侧和数据侧之间round-robin；
- AR被反压后，选中的请求来源和payload保持不变；
- AR握手后，来源锁定到该burst的`RLAST`握手；
- R响应只发给登记的请求来源。

当前PMA将8 KiB片上SRAM标记为uncached，因为其访问延迟已经很低，加入L1 tag lookup通常
不能带来收益。这个策略不取消仲裁：IFU的uncached取指和LSU的uncached SRAM访问仍分别从
instruction/data manager进入同一个core merge。PSRAM、SDRAM和ChipLink memory标记为
cacheable，其I-cache refill与D-cache refill也使用同一个仲裁点。

当前仲裁器只允许一个读burst在途，这是顺序核和单端口下游的面积可控检查点。不能把它直接
当作最终AI系统互联：多MSHR之后必须按AXI ID跟踪多个读事务，并根据下游bank和QoS决定是否
保留集中仲裁。

## 4. 正确性不变量

- 被反压的typed请求和AXI channel payload必须保持稳定。
- 一个D-cache请求只能产生一个响应；store副作用只能在一次响应握手时发生。
- dirty line在替换或clean成功前不能丢弃；writeback fault时必须保留dirty状态。
- refill最后一个beat成功前不能把新tag标记为present。
- I/D同时请求时，一个R beat只能到达一个上游；事务来源在`RLAST`前不能变化。
- `fence.i`不得在D-cache clean完成前使I-cache重新开始取指。

## 5. 已拒绝的简化

- 不把AXI五通道直接放进LSU。这样会把执行语义、cache策略和SoC协议耦合在一起。
- 不对MMIO做write-allocate，也不允许未映射地址进入cache。
- 不用固定指令优先级。持续取指会使数据侧miss长期饥饿，因此当前采用事务间round-robin。
- 不在首版提前返回critical word。当前数据子系统以LSU响应作为D-cache AXI事务结束标志；若
  在完整refill前提前返回，后续uncached请求可能抢占仍在进行的refill。实现early restart前
  必须把“LSU响应完成”和“D-cache AXI占用完成”拆成两个独立状态。

## 6. 面向AI工作负载的演进顺序

本项目最终面向本地多模态生成式AI Agent。CPU侧的关键数据负载包括runtime调度、token和
KV-cache元数据、量化解码、张量描述符以及加速器DMA控制。后续演进按以下顺序进行：

1. 加入D-cache事件监视，使用MicroBench、CoreMark和AI runtime代表性trace测量hit rate、
   miss penalty、bank冲突和I/D仲裁等待；不能只根据容量决定配置。
2. 加入store buffer和writeback queue，把store hit和dirty eviction从流水线完成路径解耦。
3. 增加多个MSHR、critical-word-first和early restart，允许hit-under-miss并形成内存级并行。
4. 将data/tag array映射为SRAM宏并分bank，给标量LSU、页表遍历和加速器一致性维护提供明确
   端口；bank数量必须由trace和面积/时序数据决定。
5. 引入LSQ、load replay和store-to-load forwarding，为OoO执行保持内存顺序和精确异常。
6. 在L2或系统缓存层处理CPU与DMA之间的共享；第一版可采用软件管理的non-coherent DMA，
   但必须定义clean/invalidate和所有权转换协议。

## 7. 当前验证

- `make test-dcache-configs PROJECT=riscv32`：RV32/RV64均通过load miss、load hit、store hit、
  dirty victim writeback和全cache clean定向测试。
- `make test-core-merge-configs PROJECT=riscv32`：RV32/RV64均通过I/D同时请求、AR反压、burst
  响应来源锁定和round-robin定向测试。
- RV32/RV64 standalone `dummy`均`HIT GOOD TRAP`。
- MicroBench `test`通过。相对相同PMU窗口的接入前记录，退休指令均为430203条，周期从
  1513766降到867290，IPC从0.284193升到0.496031，scored time从15.261 ms降到8.784 ms。
- 当前1 KiB、2-way I-cache和1 KiB、2-way、32 B line D-cache共同采用标准单元实现时，
  NanGate45综合面积为156409.064 um^2，其中时序单元占70598.262 um^2。300 MHz约束下
  WNS为+0.173 ns、TNS为0，报告频率为316.423 MHz。

## 8. 面积结论

这版D-cache证明了协议、功能和性能收益，但不满足课程25000 um^2硬约束。综合网表中包含
15111个触发器和8192个锁存器，说明cache data array被展开为标准单元存储；因此不能通过
删少量控制逻辑把面积降回目标范围。

课程签核配置不实例化这套完整D-cache，并恢复小容量I-cache后再进行面积受控的架构探索。
最终AI配置继续使用本模块边界，但data/tag array必须映射到SRAM macro；在此基础上再评估
store buffer、writeback queue、critical-word-first和多MSHR。两个配置的区别是物理实现和
资源预算，不改变LSU语义请求、PMA和AXI系统边界。
