> 历史归档，停止更新。当前实现见[现行说明](../DCACHE_DESIGN_RECORD.md)。

# D-cache微架构设计记录

> 历史设计记录：各章节反映不同阶段，早期参数和待办不一定适用于恢复的 RV32 快照。
> 当前配置、实现边界及面试表述见 [RV32 简历核对](../../interview/RV32_RESUME_AUDIT.md)。

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

关闭D-cache后的当前RV32I工程配置采用128 B、direct-map、16 B line I-cache。MicroBench
`test`中，前端供给停顿占41.471%，LSU结构停顿占30.611%，I-cache命中率为90.575%。这说明
增大I-cache后数据侧已经成为共同瓶颈，但仍不能仅根据“存在memory wall”直接分配面积给
D-cache。后续候选结构必须固定I-cache参数做A/B，分别计算减少的周期数、增加的标准单元
面积和Fmax变化。

## 9. RV32I受控面积探索结论

在相同MicroBench `test`、相同延迟模型和NanGate45流程下，把I-cache固定为256 B、
direct-map、16 B line后得到：

| D-cache配置 | 测量IPC | Fmax | 面积 | `IPC * Fmax` |
| --- | ---: | ---: | ---: | ---: |
| 关闭 | 0.221131 | 547.909 MHz | 37175.894 um^2 | 121.15 MIPS |
| 128 B/direct | 0.271584 | 518.547 MHz | 50174.516 um^2 | 140.82 MIPS |
| 256 B/direct | 0.303015 | 506.811 MHz | 58899.848 um^2 | 153.57 MIPS |
| 256 B/2-way | 0.334515 | 498.001 MHz | 59696.784 um^2 | 166.59 MIPS |

256 B/2-way相对256 B/direct只增加796.936 um^2（1.35%），测量IPC提高10.4%，综合后的
吞吐代理提高8.5%，因此选为`rv32-baseline`。128 B配置中增加关联度只有约1.75%的IPC收益，
不采用。关闭D-cache的配置每面积吞吐最高，继续作为面积敏感对照，但不再作为性能默认值。

首次综合中，当前请求的PMA结果还组合参与D-cache/uncached AXI输出选择，形成从EX经过LSU、
PMA和路由到core输出的长路径。但两个下游在请求握手首拍都不会发出有效AXI请求，该选择没有
吞吐或延迟收益。改为只使用握手后锁存的route state选择普通事务后，IPC保持0.334515，
Fmax从498.001 MHz提高到524.833 MHz，面积为59704.764 um^2。新关键路径进入D-cache同步
data array读寄存器，说明下一步必须联合设计AGU/cache请求流水和store buffer；仅插入固定
一拍的输入寄存器会增加每条访存延迟，不能直接视为有效优化。

该面积是数组被标准单元展开后的结果，不代表SRAM宏实现。必须保留D-cache、miss unit、
line AXI master和I/D仲裁边界，因为它们是后续store buffer、多MSHR、banking和LSQ的结构
基础；可以删除的是无实测收益的额外容量、额外路数和组合旁路，而不是这些协议边界。

## 2026-09-06：写数据选择路径优化

820 MHz 报告显示 lookup_s1_q 到数据阵列写数据端的控制路径处于时序边界。候选保持写使能、地址、way、字节使能和 refill 优先级不变，仅把写数据选择从 store_hit_write_occurred 解耦：无 refill 写入时始终选择 store 数据，实际写入仍须命中与响应握手。写使能无效时的数据没有架构意义；不能为缩短路径放宽写使能。保留 store bypass 和全部握手。用 D-cache、完整中断系统测试及同配置综合/STA 决定是否保留。

实测：该改动已保留，扩展 D-cache 及全部定时中断回归通过。相同配置下，820 MHz setup WNS 从负零改善为 +0.083 ns，TNS 归零；面积增加 0.48%。复位 removal 仍有违例，详见 [时序优化报告](../../verification/RV32_TIMING_FIX_2026-09-06.md)。
