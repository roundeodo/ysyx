# NPC微架构学习日志

本文件追加记录模块开发中获得的可复用经验。它不替代设计规范：已经冻结的接口、
参数和所有权写入对应的 `*_DESIGN_RECORD.md`；可复现的测量数据写入
[`EXPERIMENT_LOG.md`](../verification/EXPERIMENT_LOG.md)；这里记录从证据到工程判断的
推导过程。

## 条目模板

### YYYY-MM-DD - <模块或主题>

**开发上下文**

- 当前检查点：
- 本次问题：
- 关联设计记录：

**观察到的事实**

- 只写代码、波形、断言、综合报告、性能计数器或规范能够直接支持的事实。

**采用的设计决策**

- 记录选择、被放弃的备选方案和选择依据。

**可复用经验**

- 说明这条经验适用于哪些模块，以及它成立需要哪些前提。

**仍需验证**

- 记录尚无数据支持的假设和下一条验证命令，不把假设写成结论。

---

## 2026-07-30 - 第一版I-cache架构检查点

**开发上下文**

- 当前检查点：当前计划P1（历史编号P5A），先建立I-cache契约和教育性RTL骨架，
  不改变已验证NPC行为。
- 本次问题：当前IFU每条指令都访问SoC存储路径，取指等待占据绝大多数活动周期。
- 关联设计记录：[`ICACHE_DESIGN_RECORD.md`](../microarchitecture/ICACHE_DESIGN_RECORD.md)。

**观察到的事实**

- 基线共退休821857条指令，活动周期118497980，IPC为0.006936。
- IFU平均响应延迟为136.645周期，response-wait占活动周期的94.772%。
- 成熟前端通常将lookup pipeline、阵列、miss跟踪、refill协议和fetch buffering分开；
  这些结构解决的问题不同，不能用一个大状态机代替所有边界。

**采用的设计决策**

- v1冻结为8KiB、2-way、32B line、128 set、单MSHR、4B fetch。
- hit路径划分S0请求/索引、S1同步阵列读取、S2比较/选择，目标是两周期延迟和
  每周期一个hit lookup吞吐。
- IFU和I-cache之间使用本地typed valid/ready通道；完整AXI4只存在于refill adapter及
  core以外的系统边界。
- request身份使用`frontend_tag`，控制流有效性使用`fetch_epoch`，两者分别解决匹配和
  redirect淘汰问题。
- refill采用critical-word-first并允许early restart；v1在整条line完成前仍阻塞新lookup，
  因此没有声称支持hit-under-miss。
- data word先写，全部成功后再提交tag present，防止部分填充line被错误命中。

**可复用经验**

- 外部总线协议应停留在边界适配器。核心功能模块使用按事务语义定义的本地接口，
  才能独立更换cache、总线和SoC互连。
- “降低一次miss的可见延迟”和“允许其他请求绕过miss”是两个不同能力，性能特性必须
  用精确名称描述，避免实现和性能计数器的含义漂移。
- 阵列端口、同步读取延迟和写冲突语义应在写控制状态机前冻结，否则后续切换SRAM宏时
  会迫使pipeline和控制逻辑同时重写。
- redirect无法取消已经接受的下层事务。正确处理方式是完成协议握手，并在前端身份层
  丢弃旧epoch结果。
- 性能事件必须在事件拥有者处产生。不能从AXI读取次数反推cache miss次数，因为一次
  line miss会产生多个下层读取。
- 未完成的I-cache主体进入活动filelist时，只保留明确的停机占位输出，用于持续完成
  接口和语法检查；在主体TODO完成前，不把该配置用于功能回归。

**仍需验证**

- 8KiB/2-way/32B配置相对其他容量、way和line大小的实际收益。
- 两级同步阵列后的最大综合频率，以及S2 tag compare/word select是否成为关键路径。
- critical-word-first结合AXI4 INCR burst后的可见miss延迟和总线利用率。
- SRAM和MROM保持uncached是否优于统一cacheable策略。
- 两项以上MSHR、prefetch或way prediction中哪一项首先产生可测量收益。

## 2026-09-05：流水线中断与缓存维护边界

- 将中断移到有多个寄存级的顺序核时，不能沿用“LSU 不忙就能受理”的判断。必须覆盖执行、完成结果、LSU、写回和维护状态。恢复 PC 属于已提交路径，执行级预测纠错不能直接更新它。
- FENCE.I 开始时直接屏蔽 ready/valid 通道会撤回已呈现的请求。新系统测试触发了原 I-cache 稳定性断言；保留被背压的请求并排空，再开始缓存清理，才满足接口契约。
- Write-back 缓存下，外部 AXI 写回拍数不能与 store 指令数相等比较。分别检查指令接收/提交次数、数据读回和总线协议。

证据：[定时中断设计与回归](../microarchitecture/TIMER_INTERRUPT_DESIGN_RECORD.md)。


## 2026-09-06：分开写数据选择和写入资格

D-cache 的写入资格必须等待命中及响应握手，但写数据可以提前由 miss/store 来源选择。仅在有效写入时要求载荷正确，能减少晚到控制经过的逻辑；必须同时检查字节使能、背压和 read-during-write bypass。相同配置实测 820 MHz setup TNS 归零，面积增加 0.48%；复位 removal 是独立问题。见 [实验报告](../verification/RV32_TIMING_FIX_2026-09-06.md)。


## 2026-09-06：复位同步和复位负载要分别验证

同步释放电路解决释放与时钟的关系，但一个触发器直接驱动上千个复位端仍会因负载过大产生时序违例。本次在系统入口统一同步、下降沿释放，再在映射网表中加入非反相缓冲树，820 MHz 下包括复位在内的 max/min TNS 才归零。原始异步输入与同步释放后的路径具有不同约束边界，不能把整个复位网络一律 false-path。见 [实测记录](../verification/RV32_RESET_REDIRECT_FIX_2026-09-06.md)。


## 2026-09-15：预测器按状态归属拆分，查询按统一时刻采样

BHT、BTB、RAS 可以分别管理自己的状态，PC/epoch 和查询推进仍由预测控制模块统一管理。只拆数组、把替换和训练旁路留在父模块，会保留原来的跨功能阅读负担。BTB 的 set 快照、待写事务和连续同 set 更新旁路应一起封装。

本次保留原有采样沿，5 组参数的 120,000 周期外部输出对照通过，MicroBench 同频窗口计数完全一致。模块拆分没有增加触发器，但重新综合仍产生不同的组合映射与频率估计，因此功能等效、资源数量和时序必须分别验证。这里的仿真对照不是全状态空间的形式等价证明。

证据：[预测器拆分与验证](../verification/RV32_PREDICTOR_SPLIT_2026-09-15.md)。
