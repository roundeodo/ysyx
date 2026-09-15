# AI 处理器工作负载模型

状态：已接受，作为架构计划的负载依据

最后更新：2026-07-30

## 1. 产品场景

本项目最终面向**本地多模态生成式 AI Agent 异构 SoC**。目标设备是 AI PC、个人工作站
和紧凑型本地推理节点，不以传统工业控制器或仅运行固定视觉算法的边缘设备为产品定义。

目标系统在本地完成文本、图像、音频和工具调用任务，强调：

- 本地数据隐私和离线可用性；
- 交互式首 token 延迟和稳定的持续生成吞吐；
- 在有限功耗和内存容量下运行量化模型；
- CPU、向量单元、AI 加速器、DMA 和内存系统的协同；
- 能够运行完整操作系统、AI runtime 和 Agent 控制软件。

MLCommons 的 MLPerf Client 将代码分析、内容生成、创作和摘要列为本地 LLM 的代表任务，
并使用首 token 时间等指标评价用户体验。这些公开任务用于约束本项目的负载选择，而不是
把某个 benchmark 的单一分数当成全部设计目标。

## 2. 目标负载

### 2.1 生成式语言模型

第一阶段面向 3B 至 14B 参数的 INT4/INT8 量化模型推理，覆盖：

- 短提示和长提示的 prefill；
- 自回归 decode；
- KV cache 读写；
- tokenizer、sampling、logits 后处理和 runtime 调度；
- 多轮 Agent 的工具调用、上下文管理和小任务并发。

prefill 具有较高并行度和计算密度；decode 每次生成少量 token，容易受到权重、KV cache
和中间数据搬运延迟影响。两者不能只用一个“AI 算力”指标描述。

### 2.2 多模态前后处理

- 图像缩放、归一化、布局变换和 patch 生成；
- 音频分帧、特征提取和流式缓冲；
- 小型视觉编码器或语音编码器的控制与调度；
- 多个 accelerator kernel 之间的张量描述符和队列管理。

这些工作包含大量短循环、条件控制、地址计算和非规则数据移动。CPU 不能只作为启动
加速器后长期空闲的控制器。

### 2.3 系统软件

- RV64 操作系统、虚拟内存、异常和中断；
- AI runtime、内存分配器、线程和同步原语；
- DMA 描述符、命令队列和完成队列管理；
- 设备驱动、网络和存储 I/O；
- 调试、性能监控和安全隔离。

## 3. CPU 与加速器分工

### CPU 必须高效完成

- 操作系统和 runtime 控制流；
- 指针追踪、分支密集代码和短标量循环；
- tokenizer、sampling、数据格式转换和地址生成；
- accelerator 命令提交、依赖管理、异常处理和完成回收；
- 无法高效映射到矩阵阵列的小算子和尾部处理。

### 向量或矩阵加速器负责

- 大规模 GEMM/GEMV；
- attention 中规则的向量和矩阵运算；
- 卷积、激活、归一化和量化内核；
- 高吞吐张量搬运与格式转换。

因此，最终产品是异构 SoC。仅扩大标量乱序窗口不能替代 AI 加速器；只设计加速器而忽略
CPU、cache、DMA 和软件栈，也无法形成可用系统。

## 4. 对 CPU 微架构的要求

### 4.1 RV64 和完整系统能力

- 最终 ISA 基线为 RV64，32 位指令宽度与 `XLEN` 解耦；
- 支持 U/S/M 特权级、Sv39、原子操作和完整异常模型；
- 以标准 RISC-V Vector 1.0 为向量能力的首选接口；
- 自定义矩阵或 AI 扩展必须由真实 kernel 的 profiling 结果驱动。

### 4.2 前端

- 分支预测与取指解耦，允许后续加入 FTQ 和 fetch buffer；
- I-cache、ITLB、预取和 miss 处理具有独立所有权；
- 能够隐藏较大的指令存储延迟，并统计每一种前端停顿原因；
- 支持可恢复的 redirect、异常和错误路径响应丢弃。

### 4.3 后端

- 先形成可验证的顺序流水线，再演进到 rename、ROB、调度、发射、执行和提交分离的 OoO；
- 提交是架构状态更新和性能计数的唯一权威边界；
- LSU 具有显式 load/store queue、访存顺序和 store 提交规则；
- 为向量和 accelerator 指令预留长延迟执行及完成接口。

### 4.4 存储系统

- I-cache、D-cache、TLB 和共享缓存必须参数化，但只支持经过验证的合法配置；
- 重点测量 cache miss、内存级并行度、带宽利用率和 KV cache 数据流；
- accelerator 通过 DMA 或一致性端口访问内存，具体一致性策略必须显式记录；
- cache line、总线 beat 和软件页大小不能混为同一个参数。

## 5. 评价指标

### 5.1 用户级 AI 指标

- 首 token 时间；
- decode tokens/s；
- prefill tokens/s；
- 每 token 能耗；
- 可运行模型大小和长上下文容量；
- Agent 多轮任务完成时间。

### 5.2 CPU 和存储指标

- retired IPC、分支 MPKI 和错误预测恢复代价；
- I-cache/D-cache/ITLB/DTLB MPKI；
- 前端供给率、后端阻塞率和 ROB 占用率；
- load 使用延迟、LSQ 阻塞和内存级并行度；
- 有效内存带宽和总线利用率；
- accelerator 提交率、利用率、DMA 等待和中断服务延迟。

所有指标必须按 workload 阶段分别记录。把 prefill、decode 和系统初始化阶段混合成一个
平均值，会掩盖真实瓶颈。

## 6. 第一批代表程序

在能够运行完整 AI 模型之前，使用可逐步扩展的代理负载：

1. `microbench`：建立 CPU、cache 和总线的可重复基线；
2. tokenizer/sampling 小程序：覆盖分支、查表和短循环；
3. GEMV 与量化解码 kernel：覆盖 INT4/INT8 数据组织和内存带宽；
4. attention/KV cache microbenchmark：覆盖长序列读取和工作集变化；
5. runtime command queue：覆盖 CPU、DMA 和 accelerator 的协同；
6. 量化小模型端到端推理：最终验证用户级指标。

## 7. 一手资料

- [MLPerf Client](https://mlcommons.org/benchmarks/client/)：本地生成式 AI 的任务和指标。
- [RISC-V Vector Extension 1.0](https://docs.riscv.org/reference/isa/extensions/vector/_attachments/riscv-v-spec.pdf)：标准向量 ISA。
- [XiangShan 设计文档](https://docs.xiangshan.cc/)：高性能 RISC-V 前后端和 cache 的模块边界。
- [PULP Ara](https://github.com/pulp-platform/ara)：RV64 核与标准向量协处理器的组合。
- [PULP Snitch](https://github.com/pulp-platform/snitch_cluster)：标量核、数据搬运和加速集群的组织方式。

引用这些项目是为了学习契约、所有权和验证方法。任何本地设计选择仍需由本项目的负载、
资源和实验结果决定。
