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


## 2026-09-05：重定向之后完成的旧请求不能更新恢复 PC

RV32 中断联调的 AM C 程序暴露了旧 IFU 的时序缺陷。请求在 valid/ready 通道等待时，
redirect 更新了恢复 PC；旧请求随后握手又写入旧 PC+4，覆盖新目标。

请求 payload 保持稳定和恢复目标保持正确是两项不同要求。旧请求仍要完成握手，但只有
请求 epoch 与当前控制流一致时才能更新顺序 PC。独立 IFU 测试在修复前失败、修复后通过，
AM C 程序也通过，证据见本次定时器中断实验记录。
