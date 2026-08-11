# 面向本地多模态生成式 AI Agent 的 NPC 架构计划

状态：当前设计权威

当前实现基线：RV32I、多周期、单发射、顺序提交；core系统边界统一使用完整AXI4

最终产品目标：RV64 异构 AI SoC 主处理器

最后更新：2026-08-01

## 1. 文档目的

本文档固定产品场景、架构边界、参数化策略和演进顺序，避免随着局部问题改变最终方向。
模块设计记录可以细化本文档，但不能在未更新决策记录的情况下改变本文档冻结的边界。

旧版 RV32 双发射 OoO 计划已经归档到
[`archive/RV32_ARCHITECTURE_PLAN_2026-07-30.md`](archive/RV32_ARCHITECTURE_PLAN_2026-07-30.md)。
它用于追溯当前 RTL 的形成过程，不再定义最终产品。

## 2. 产品定位

最终产品是面向 AI PC、个人工作站和紧凑型本地推理节点的**本地多模态生成式 AI Agent
异构 SoC**。CPU 是系统主处理器，负责操作系统、AI runtime、控制流、数据准备、调度、
异常和 I/O；规则且计算密集的张量运算由向量或矩阵加速器完成。

本项目不以以下方向作为最终定位：

- 只运行固定视觉算法的传统工业控制 SoC；
- 只追求 CoreMark 分数而没有 AI 工作负载的通用 CPU；
- 用大型 OoO 标量核心替代矩阵加速器；
- 只实现加速器而没有完整系统软件能力的演示电路；
- 数据中心训练级多 socket 服务器。

详细负载和指标见[`AI_WORKLOAD_MODEL.md`](AI_WORKLOAD_MODEL.md)。

## 3. 分阶段 ISA 策略

### 3.1 当前课程基线

保留 `YSYX_RV32_BASELINE`：

- RV32I 及当前课程所需 CSR、异常、中断和 SoC 功能；
- 继续用于 ysyx 阶段任务、快速功能调试和 DiffTest；
- 不因最终转向 RV64 而破坏已经可运行的回归基线。

### 3.2 最终产品基线

目标配置逐步形成 RV64GCV 系统能力：

1. RV64I、Zicsr、Zifencei；
2. M、A、C 和必要的浮点能力；
3. U/S/M 特权级、Sv39 和页级内存保护；
4. RISC-V Vector 1.0；
5. 由真实 AI kernel 证明收益后，再评估矩阵或自定义扩展。

ISA 列表是实现顺序，不要求一次完成。每增加一个扩展，都必须先加入参考模型、定向测试、
异常语义和软件工具链验证。

## 4. 宽度解耦

以下宽度必须独立配置：

| 参数 | 含义 | 当前基线 | 长期方向 |
| --- | --- | --- | --- |
| `XLEN` | 整数寄存器和标量运算宽度 | 32 | 64 |
| `INST_WIDTH` | 基础指令容器宽度 | 32 | 32 |
| `VADDR_WIDTH` | 虚拟地址宽度 | 32 | Sv39 对应实现宽度 |
| `PADDR_WIDTH` | 物理地址宽度 | 32 | 由 SoC 地址图决定 |
| `CORE_DATA_WIDTH` | core/cache 数据通路宽度 | 32 | 64 或更宽的内部 beat |
| `SOC_AXI_DATA_WIDTH` | ysyxSoC 边界宽度 | 32 | 初期保持 32 |

RV64 core 接入当前 32 位 ysyxSoC 时，由边界 adapter 拆分 64 位 load/store。CPU 内部不能
因为当前 SoC 端口是 32 位，就继续把 `XLEN`、地址和 cache beat 写死为 32 位。

## 5. 参数化和合法配置

参数化与模块化的固定规则见
[`DEVELOPMENT_PROCESS.md`](../development/DEVELOPMENT_PROCESS.md)。架构层冻结以下要求：

1. 参数集中在配置 package 或命名配置中，模块内部只计算派生参数；
2. fetch/decode/issue/commit 宽度分别命名，不能用一个 `WIDTH` 代替；
3. cache 容量由 set、way、line bytes 推导，不直接维护互相重复的容量参数；
4. 队列、ROB、LSQ、MSHR 和物理寄存器数量均有 elaboration-time 合法性检查；
5. 使用数组和 `generate` 扩展 lane、bank 和 way；
6. 只承诺命名配置通过完整回归，不承诺任意参数笛卡尔积都合法；
7. 参数改变数据形状时，名称必须使用 `_array`、`_vector` 或 `_index` 明确表达。

## 6. 顶层系统结构

```text
AI application / runtime / operating system
                    |
       +------------+-------------+
       |                          |
  RV64 host core             AI accelerator cluster
       |                          |
  L1 I$/D$ + MMU       command/completion + local memory
       |                          |
       +------- shared interconnect/DMA -------+
                                                |
                                     shared cache / memory ctrl
                                                |
                                         DRAM and devices
```

CPU、加速器、DMA 和外设使用显式事务通信。命令队列、完成队列、中断、内存一致性和错误
传播都必须形成接口契约，不能依赖 top 中的隐式组合逻辑。

## 7. CPU 模块边界

### 7.1 Frontend

- `branch_predictor`：预测方向和目标；
- `ftq`：保存预测取指流及恢复元数据；
- `ifu`：生成取指事务、处理 redirect 和错误路径响应；
- `icache`：指令存储、lookup、miss 和 refill；
- `itlb`：地址翻译和权限检查；
- `fetch_buffer`：将可变延迟取指与后端解耦；
- `idu`：指令边界、预译码、译码和 uop 生成。

这些模块可以在早期配置中合并实例，但所有权必须在类型和接口中保持可分离。

### 7.2 Backend

- `rename`：架构到物理寄存器映射和资源分配；
- `rob`：指令年龄、完成、异常和顺序提交；
- `dispatch`：把 uop 分配给调度队列；
- `issue_queue`：操作数就绪、选择和发射；
- `exu`：整数、分支、乘除和地址生成；
- `lsu`：load/store queue、顺序检查、转发和 cache 请求；
- `writeback`：把执行结果写回物理状态；
- `commit`：唯一架构状态更新边界；
- `csr/trap`：特权状态、异常和中断；
- `pmu`：架构计数器和可选的实现事件计数器。

### 7.3 Memory hierarchy

- I-cache 和 D-cache 分别拥有自己的 lookup、阵列和 miss 状态；
- refill/writeback adapter 负责 cache line 与 SoC beat 转换；
- L2 或系统缓存负责跨 master 的共享和带宽整形；
- PMA/PMP、MMU 和 cacheability 决策必须在请求进入 cache 前明确；
- MMIO 不能被普通 cache line 隐式缓存。

### 7.4 AI system interface

第一版加速器接口使用：

- command queue：操作码、张量描述符地址、依赖和上下文；
- completion queue：完成状态、错误和性能信息；
- DMA：独立于 CPU load/store 的大块数据移动；
- interrupt：完成、错误和超时通知；
- PMU events：提交、执行、带宽、等待和利用率。

是否使用硬件 cache coherence 必须经过 workload 和成本评估。第一版允许软件显式管理的
non-coherent DMA，但其所有权和 cache 维护操作必须写入契约。

## 8. 内部通道规范

模块之间使用 typed `valid/ready/payload` 通道，载荷按事务语义定义。禁止用一组没有类型
归属的零散控制线跨越多个层级。

每个通道必须定义：

- 请求和响应的开始/结束握手；
- payload 在反压期间的稳定性；
- 最大未完成事务数和排序规则；
- redirect、flush、异常和 reset 对在途事务的处理；
- 错误返回及相关地址元数据的所有者；
- 同周期 fast bypass 和寄存器后备路径。

SoC AXI、APB 或 TileLink 只存在于系统边界和 adapter 中。IFU、LSU 和执行单元不直接拥有
特定外部总线协议。

## 9. uop 和精确状态

统一 uop 至少携带：

- `valid`、PC、指令和预测元数据；
- 操作类别、源/目的逻辑寄存器和立即数；
- 执行单元、访存宽度、符号扩展和 CSR 控制；
- rename 后物理寄存器、ROB index、LSQ index；
- 异常、访问错误和 redirect 元数据。

不用某个字段的指令仍使用同一 uop 类型。硬件面积由实际寄存器、队列和综合优化决定，
不能为减少结构体中的无关字段而破坏模块接口的一致性。进入流水寄存器或队列的字段才会
形成存储成本，因此每个级间边界仍需审查实际保存的字段。

## 10. 性能目标和证据

当前阶段不冻结脱离 workload 的绝对 IPC 或主频目标。每个检查点必须同时记录：

- 功能回归结果；
- retired instructions、cycles 和 IPC；
- 分支、cache、TLB、LSU 和总线计数器；
- 综合频率、WNS 和面积；
- AI 代理负载或端到端负载的用户级指标。

优化只能由计数器和实验支持。不能因为某个结构在成熟项目中存在，就直接认定它对当前
配置有收益。

## 11. 验证架构

### 11.1 功能验证

- RV32 基线继续使用 NEMU DiffTest 和 AM 回归；
- RV64 阶段先扩展参考模型和 AM 运行环境，再迁移模块；
- 指令扩展均有 directed test、随机指令和异常测试；
- cache、总线和队列使用随机背压、随机延迟和错误注入；
- precise exception、redirect 和 store 可见性使用断言验证。

### 11.2 性能验证

- `make perf` 运行固定 workload 和命名配置；
- `make perf-record` 绑定 Git commit 并追加实验记录；
- 开发版快速仿真与 ysyxSoC 细节仿真分别使用，但不能混合结果；
- 每项优化在同一 workload、工具和配置下进行 A/B 比较。

### 11.3 参数验证

- 每个命名配置都有独立构建和回归；
- 最小/最大边界参数有 elaboration 测试；
- 宽度变化覆盖类型、数组、循环和地址切片；
- 非法组合必须在 elaboration 阶段明确报错。

## 12. 实施路线图

### P0：冻结 RV32 ysyx 基线

状态：已完成并持续回归。

- 单周期演进到可变延迟多周期；
- 旧总线基线仅保留在Git历史；活动RTL不保留兼容实现；
- I-cache/LSU使用本地语义接口，core边界统一使用完整AXI4；
- AM、RT-Thread、DiffTest、trace 和 PMU；
- 保存稳定的 `YSYX_RV32_BASELINE`。

### P1：完成参数化 I-cache

状态：进行中。

- 当前检查点：8 KiB、2-way、32 B line、blocking miss；
- meta/data/miss/refill/PMA分离，refill通过完整AXI4 INCR burst取回cache line；
- 参数合法性检查、随机延迟、redirect 和 `fence.i`；
- 记录命中率、平均取指延迟、WNS 和面积。

设计依据见[`ICACHE_DESIGN_RECORD.md`](../microarchitecture/ICACHE_DESIGN_RECORD.md)。

### P2：建立配置层并解耦所有宽度

- 创建统一配置 package 和命名配置；
- 分离 `XLEN`、地址、指令、core 数据和 SoC 总线宽度；
- 清除散落的 `32`、固定 lane 和固定寄存器数；
- 建立 64-bit core 到 32-bit AXI 的 adapter 单元测试。

### P3：RV64 顺序功能基线

- RV64I 寄存器、ALU、load/store、CSR 和异常；
- RV64 AM、NEMU DiffTest 和软件工具链；
- 分级流水线、旁路、冒险和精确异常；
- 保持 RV32 与 RV64 两个命名配置均可回归。

### P4：系统软件基础

- M/S/U 特权级、Sv39、ITLB/DTLB 和 page fault；
- 原子指令和多核/设备同步所需语义；
- Linux 或等价完整 OS 启动；
- D-cache、写缓冲和共享内存系统。

### P5：Width-1 OoO 骨架

- rename、物理寄存器、ROB、issue queue 和顺序 commit；
- 单发射用于先验证精确状态和恢复；
- LSU 加入 LSQ 和 store 提交规则；
- 与顺序核使用同一 ISA、cache 和验证接口。

### P6：超标量 OoO

- 先扩展到 2-wide，再根据证据评估 4-wide；
- 多 bank 队列、物理寄存器端口和写回仲裁；
- 分支检查点、快速恢复和更强预测器；
- 非阻塞 cache、多 MSHR 和内存级并行度。

### P7：标准向量能力

- 实现或接入 RISC-V Vector 1.0；
- 向量寄存器、长延迟执行、访存和异常；
- 使用 GEMV、量化解码和前后处理 kernel 验证；
- 评估 tightly-coupled 与 coprocessor 两种边界。

### P8：AI accelerator 子系统

- command/completion queue、DMA、中断和错误模型；
- 矩阵运算、量化和 attention 数据流；
- 显式 non-coherent 或 coherent 内存策略；
- 端到端小模型推理和 Agent runtime。

### P9：AI workload 驱动优化

- 分别分析 prefill、decode 和多模态前后处理；
- 优化 cache、预取、内存带宽、DMA 和 accelerator 利用率；
- 记录 TTFT、tokens/s、能耗代理指标、面积和时序；
- 只有测得收益的特性进入正式配置。

## 13. 当前目录边界

```text
npc/vsrc/riscv32/
  common/          package、配置、公共类型
  core/
    frontend/      predictor、IFU、I-cache、fetch buffer
    backend/       rename、ROB、schedule、execute、LSU、commit
    memory/        cache adapter、TLB、MMU、PMA/PMP
  system/          interconnect、adapter、peripheral
  sim/             仅供仿真的模型和顶层
  filelist/        命名配置的源码列表

npc/docs/
  architecture/    产品、负载和架构计划
  development/     开发流程、命名和模板
  interconnect/    总线和互连记录
  microarchitecture/  模块设计记录
  verification/    实验与回归结果
  learning/        学习记录
```

目录布局可以随模块增长调整，但依赖方向固定：`common` 不依赖功能模块，core 不依赖仿真
模型，外部协议通过 system adapter 接入，文档不再散落在 RTL 子目录。

## 14. 决策记录

### D001：保留 RV32 基线，最终迁移到 RV64

原因：ysyx 当前回归和已完成 SoC 工作建立在 RV32 上；本地 AI Agent 的地址空间、系统
软件和向量生态需要 RV64。采用并行命名配置而不是一次性替换。

### D002：最终产品采用异构 AI SoC

原因：AI workload 同时包含控制、数据移动和密集张量计算，单一标量 core 不能高效覆盖。

### D003：参数化只承诺命名配置

原因：任意参数组合会形成不可验证的状态空间。成熟工程需要配置管理和回归闭环，而不是
只有语法层面的 parameter。

### D004：内部协议与 SoC 协议分离

原因：IFU、LSU、cache 和 accelerator 的架构职责不应被当前 AXI/APB 端口绑定。

### D005：模块设计必须留下记录和实验

原因：本项目的目标包括学习先进团队的工程方法。没有决策依据和验证证据的 RTL 不能形成
可维护经验。

## 15. 变更流程

修改冻结决策时必须：

1. 在相关模块设计记录中给出问题和证据；
2. 比较至少两个可行方案；
3. 说明对软件、RTL、验证、性能和迁移的影响；
4. 在本节增加新决策并标记被替代项；
5. 更新命名配置、回归和实验记录。

口头讨论或临时 TODO 不能覆盖本计划。
