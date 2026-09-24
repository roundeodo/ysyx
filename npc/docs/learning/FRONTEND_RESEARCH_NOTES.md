# RV32 前端探索：文献、实现与设计取舍

整理于 2026-09-22。本文保存可复核的研究依据、设计假设、比较方法和取舍，供后续学习。
它是学习入口；当前电路以模块说明为准，完整参数、测量和命令以验证记录为准。
后续有新证据时更新对应结论，保留旧实验，不把初步设想改写成已经完成的工作。

## 1. 从哪里开始读

建议按以下顺序，把论文中的问题对应到真实代码和测量：

1. [最终选型记录](../verification/ICACHE_SELECTION_2026-09-21.md)：先理解目标、负载、对照和适用范围。
2. 本文第 2、3 节：区分论文原方案、实际借鉴和本核的简化。
3. [替换电路说明](../microarchitecture/ICACHE_REPLACEMENT_DESIGN.md)与
   [RTL](../../vsrc/riscv32/core/frontend/riscv32_icache_replacement.sv)：追踪状态、组合更新和查询前递。
4. [C++ 模型](../../tools/icache_explore/model.cpp)与
   [整核配置矩阵](../../scripts/select_icache.py)：理解筛选模型与真实执行时间的边界。
5. 本文第 4、5 节及对应机器数据：检查是否真正隔离了容量、策略、电路和频率的影响。
6. 本文第 6 节：区分 I-cache 阶段与后续分支研究，核对各自实际完成的范围。

本轮基线 commit 为 `47c852e12b9ce086b872095f59cf54fbe5a6fda6`，探索还有未提交修改；
单凭 commit 不能重建实验。源码、差异、工具和镜像身份见
[基线清单](../verification/data/icache-selection-20260922/baseline-manifest.json)、
[工具清单](../verification/data/icache-selection-20260922/tool-manifest.json)和
[镜像清单](../verification/data/icache-selection-20260922/images-manifest.json)。

## 2. 论文与项目：读什么，实际用了什么

下表记录本轮学习和实现的范围，不代表已复现论文全部机制。作者稿和项目链接用于阅读；
没有冻结作者 artifact 的版本及运行环境，就不能声称作者实验已可复现。

| 阅读材料 | 学习重点与原系统边界 | 本核采用程度 |
| --- | --- | --- |
| [RRIP，ISCA 2010](https://jaleels.org/ajaleel/publications/isca2010-rrip.pdf) | 插入、命中提升和替换老化分别控制什么；原评估主要面向 LLC | 经典基础与简单对照。当前策略沿用两位 RRPV，不将其称为近期创新 |
| [ACIC，2022 年公开稿](https://arxiv.org/abs/2211.10480) | 连续空间访问与后续复用的区别；原方案包含 i-Filter 和准入预测，评估含 32 KiB/8路 L1I | 借鉴访问特征，改为分段命中提升；没有实现完整过滤器或准入预测器。这是当前所选策略最直接的研究来源 |
| [GHRP，ISCA 2018](https://www.elbagarza.com/pdfs/ghrp_isca2018.pdf) | 用历史上下文预测条目复用；研究覆盖 I-cache 与 BTB，不能等同分支方向预测 | 实现过简化的 PC/路径复用学习原型，未选入当前预设；没有将该策略部署到 BTB |
| [Bumper，ISCA 2026](https://www.pure.ed.ac.uk/ws/portalfiles/portal/654859698/VavouliotisEtalISCA2026Bumper.pdf) | 用退休信息确认指令行有用性；原系统为大型乱序核、192 KiB L1I、6 MiB 统一 L2，并有 FDIP | 第一阶段实现过面向小 L1I 的退休反馈候选；未胜过简单对照，当前预设不启用 |
| [ICARUS，ASPLOS 2026](https://webs.um.es/aros/papers/pdfs/vkalbande-asplos26.pdf) | 用历史上下文、关键性与复用信息管理 L2；原评估有 64 KiB L1I、2 MiB L2 | 阅读与适用性分析，没有完整实现 ICARUS；自写路径学习表不能冒称该论文复现 |
| [Mockingjay，HPCA 2022](https://www.cs.utexas.edu/~lin/papers/hpca22.pdf)；[作者项目](https://github.com/ishanashah/Mockingjay) | 从是否复用推进到复用距离预测；核算采样器、预测表、时间状态，原目标为 LLC | 已有记录核验项目及 Apache-2.0 许可；未复制代码或完整移植。先用 OPT 估计空间，避免给小 L1I 直接加大预测器 |
| [Wrong-Path-Aware Entangling，IEEE TC 2024](https://webs.um.es/aros/papers/pdfs/aros-tc24.pdf)；[作者项目 TC-24](https://github.com/alberto-ros/EntanglingInstructionPrefetcher/tree/main/TC-24) | 错误路径训练、关联预取及恢复；原系统有深 FTQ、L2 和较大关联表 | 已有记录核验作者项目，未移植。当前阻塞 L1I 没有第二个同时服务的 miss，须先分开评估并发基础结构与预取策略 |
| [TRRIP，2025 年预印本](https://arxiv.org/abs/2509.14041) | 编译器分类、代码布局和页属性的软硬件协作前提 | 仅适用性筛选；固定镜像、无 MMU 的本轮未实现，不把它改称普通在线热点计数器 |
| [SmartScout，ICS 2026 出版入口](https://doi.org/10.1145/3797905.3815060) | BTB 预填充方向的后续阅读入口 | 仅初筛；当时全文入口受限，作者 artifact 未核验。不得写成已完成全文研究、模型或 RTL 实验 |

Bumper、ACIC、GHRP、ICARUS 的作者公开 artifact 在本轮没有取得并完成核验；这不表示
它们一定不存在。已实现的简化 RTL 是本项目自行编写，不能把作者论文收益作为本核收益。
原系统资源与第一轮否决依据详见[第一阶段文献记录](../verification/FRONTEND_EXPLORATION_2026-09-21.md)
和[容量阶段记录](../verification/ICACHE_CAPACITY_EXPLORATION_2026-09-21.md)。

实际负载还使用了两个值得阅读的开源项目：

| 项目 | 本轮用途 | 版本与移植边界 |
| --- | --- | --- |
| [cJSON](https://github.com/DaveGamble/cJSON/tree/6d9f2443ab071f86e5d9b43025a40929ec41c46c) | JSON 请求解析、BPE 与 runtime 图控制路径 | 数字解析改为带溢出检查的 32 位整数，只使用 valueint，不承诺完整浮点 JSON 兼容 |
| [miniz](https://github.com/richgel999/miniz/tree/77d0dce8627735138c51770d1799a1ef48f2117d) | zlib 解压后做 INT4 解包和布局转换 | 使用 inflate 路径及相应裁剪配置；独立 Python zlib 校验结果 |

原始文件哈希、许可证与移植差异统一保存在[第三方清单](../../tests/frontend_selection/vendor/manifest.json)。
这些是实际可校验的 CPU 软件代理，不是完整模型推理或 MLPerf 成绩。

## 3. 当前策略怎样从研究观点变成电路

当前均衡预设为 1 KiB、4 路、32 B 行、策略 13；配置入口是
[rv32-balanced.mk](../../configs/rv32-balanced.mk)，原基线仍可选。
下面仅解释该策略，不把其他候选的机制归入当前实现。

### 3.1 要验证的假设

一条 32 B 行包含 8 条 RV32I 指令。首次回填后，顺序取出剩余指令也会连续命中。
这些命中能够说明行内空间局部性，却不足以证明这段代码之后会再次使用。
因此假设：延迟这类命中的保留优先级提升，可能减轻单次经过代码对其他行的挤占。
这是可检验的假设，不是所有程序均成立的结论。

ACIC 用过滤器和预测器进一步区分访问。这里仅借鉴它对访问性质的区分，采用低成本判据：
保存前一次已接受访问的行地址；当前行不同，就开始新的访问段。

### 3.2 策略规则与源码对应

| 事件 | 普通 SRRIP | 当前分段访问 RRIP |
| --- | --- | --- |
| 新行分配 | 插入 RRPV=2 | 相同 |
| 连续命中同一行 | 命中行 RRPV=0 | 不因该命中提升 |
| 访问其他行后再次命中 | 命中行 RRPV=0 | 相同，此时确认一次跨段复用 |
| 全组有效，需要替换 | 选最大 RRPV，必要时老化 | 相同；空行仍由 I-cache 主体优先选择 |

阅读 RTL 时依次查找 `access_event`、`access_line`、`previous_line_q`、`burst_start`、
`rrpv_array_d`、`read_rrpv_array` 和 `read_victim_o`。
策略 13 的 `BURST`、`QUERY_BYPASS` 为真，`LEARNED`、`PATH_HISTORY` 为假。
它没有使用退休确认或 PC/路径学习表；源码中其他策略的状态会被常量传播删除。

相对同结构普通 RRIP，分段判断新增 27 位行地址和 1 位存在标志，还要计算地址比较的成本。
这 28 位不是整个替换器的面积；原有每行 RRPV、查询快照和组合选择逻辑仍然存在。
状态只按命中响应握手或 miss 接收更新，反压期间不能按 valid 每拍重复训练。
复位和 FENCE.I 失效清除相关历史；普通 redirect 不撤销已经发生的物理缓存访问。

该判据也会把完全位于同一行内的循环当成连续访问，不知道未来是否复用，并可能受错误路径
访问影响。这些是机制局限，不能从整核平均收益推断它总能识别“只执行一次”的代码。

### 3.3 查询旁路是独立的电路选择

当前阻塞式 I-cache 的 miss 分配与新查询互斥。因此，查询只需读取当前 RRPV，并前递
同组、同拍命中造成的提升，不必穿过分配时的全组老化和插入网络。
完整状态更新仍保留，victim 编号与 tag 读取处于同一寄存边界，不新增流水级或等待。
这里的旁路是替换元数据的查询前递，不是“不安装某些缓存行”的 cache admission bypass。

前提由互斥断言及测试覆盖。如果以后加入 hit-under-miss 或多个 miss，必须重新检查，
不能直接沿用这个互斥假设。详见[电路与恢复条件](../microarchitecture/ICACHE_REPLACEMENT_DESIGN.md)。

## 4. 怎样筛选，并把收益归因分清

目标在看保留集前确定：通过正确性和全部 STA 检查后，优先降低全核面积乘执行时间；
三个 AI 代理类别等权，限制单项退化。开发种子为 41/73，保留种子为 809/1543。
MicroBench 单独参照，不把它计入 AI 代理评分。

| 要回答的问题 | 对照或证据 | 可支持的判断 |
| --- | --- | --- |
| 值不值得先改善 I-cache？ | 原基线代理负载的前端等待分类，加只改 I-cache 的整核实验 | 等待统计提示方向；单项改动验证实际收益，不能把等待比例全当可消除罚时 |
| 更大容量是否足够？ | 模型扫描到 16 KiB，保留容量、路数、行大小的单项对照 | 不能把容量或相联度收益全部归给替换算法 |
| 策略有没有理论空间？ | 同一轨迹、同映射的简单策略与离线 OPT | OPT 只给模型中的缺失空间，不预测 CPU 加速比 |
| 访问段判断是否有用？ | `c1sbypass32`（策略14）对 `c1bypass32`（策略13） | 相同查询电路上隔离分段规则：开发集同频周期几何平均减少约 2.66% |
| 查询旁路是否有效？ | `c1b32`（策略9）对 `c1bypass32`（策略13） | 同频周期及全部计数器相等，STA 通过点由 600 到 720 MHz；属于电路收益 |
| 是否胜过强简单对照？ | 同为 1 KiB/4路/32 B 的 `c1legacy32`（原 SRRIP，策略1） | 保留集各自合法频点平均用时仅减少约 0.52%，面积时间积减少约 1.13% |

策略 1 与策略 14 的查询/更新边界不同，因此不能用“同为 SRRIP”忽略基础电路差异。
完整消融见[22组对照](../verification/data/icache-selection-20260922/ablations.json)，
旁路等周期证据见[查询等价记录](../verification/data/icache-selection-20260922/physical-query-equivalence.json)。

方法分为两层：先用 C++ 退休 PC 回放扫描 910 个几何/策略组合，再对筛出的 30 项做
整核 RTL、面积和 STA。模型包含 13 种在线策略及 OPT 上界，不含错误路径时序或总线竞争；
它只筛选缺失、回填流量和访问活动，不输出实际 IPC 或执行时间。
模型初筛、RTL 实现和最终采用是三个不同状态，不能相互代替。

最终使用统一 AREA3 映射流程，并让基线也重新综合；历史 DELAY 0 的 580 MHz 与本轮
基线的 800 MHz 不能混为同一综合结果。跨频率比较必须保持外部物理延迟，重新仿真；
不能把旧周期数直接除以新频率。累计物理时间的 RAM 模型修正、统一频率比较、STA 四组
检查及 SoC 原生计时的区别，统一见[选型记录的综合与计时口径](../verification/ICACHE_SELECTION_2026-09-21.md)。

## 5. 为什么没有选择更复杂的机制

| 候选或选择 | 证据支持的取舍 | 结论边界 |
| --- | --- | --- |
| Bumper 启发的退休反馈 | 第一阶段在原有负载和模型下，收益不足以抵消频率与成本 | 保留负结果；不与修正 RAM 模型后的新数据混排，也不否定原论文的 L2 场景 |
| PC/路径复用学习表 | 部分模型点有潜力，但增加签名、训练、表读写成本；1 KiB 路径旁路原型仅通过 460 MHz，开发集面积时间积更差 | 保留原型，不在当前预设启用；不能凭缺失率下降就选硬件 |
| 更大容量 | 2 KiB 候选开发集更快，但全核面积时间积劣于所选 1 KiB | 选择均衡点，不声称 1 KiB 是所有程序、工艺和 SRAM 实现的最优容量 |
| 完整预取方案 | 当前没有新增 miss 并发和所需身份管理；相关原论文资源前提差异明显 | 尚未实现预取，不把此轮说成预取探索已完成 |
| 所选分段策略 | 相对小基线的大幅收益主要来自缓存组织；相比强简单对照的额外优势很小 | 仅在声明的负载、存储模型、综合流程和目标函数下采用 |

负面结果也必须学习：20/10 ns 存储模型下，所选策略比简单 SRRIP 平均慢约 0.80%，
最差单项慢约 3.96%；MicroBench test 的 Total/Scored 时间分别慢约 3.87%/4.58%。
因此保留简单对照和原基线入口，不宣称所有负载都更快。没有可靠功耗测量，只报告访问与流量。

后续用户运行的 [MicroBench train 报告](../../result/performance/passive-train-20260922T071755Z/report.json)
是新增的单配置测量，不是此前用于选型的输入，也没有单凭这次结果证明优于同条件 SRRIP。
Total 与 Scored 的 IPC 必须分别使用各自窗口的退休数和周期数，不能交叉相除。

## 6. 分支预测：与 I-cache 研究的边界

I-cache选型阶段保持BHT/BTB/RAS不变，只补充分支错误统计；当时还没有完成独立分支探索。
后续于2026-09-23完成[分支研究](BRANCH_RESEARCH_NOTES.md)及
[实验记录](../verification/BRANCH_EXPLORATION_2026-09-22.md)：重新测量瓶颈，核验论文与
作者实现，比较模型、简单表项扩容、BTB准入及RRIP/LRU的RTL，完成正确性、PPA和保留集。
按事先约定的面积×执行时间指标保留BHT16/BTB16/RAS4，实验机制默认关闭。

[历史Branchsim](../../tools/branchsim/branchsim.cpp)与
[早期记录](../microarchitecture/BRANCH_PREDICTION_DESIGN_RECORD.md)保留原实验；当前查询和
训练时序以[取指预测器说明](../microarchitecture/FETCH_PREDICTOR_DESIGN_RECORD.md)为准。
I-cache路径复用预测、分支方向预测和BTB目标管理是不同问题。后续分支轮没有声称实现
完整GHRP、Thermometer、MORSL或TAGE，也没有增加推测历史检查点；这些边界仍须保留。

## 7. 如何沿证据复习和复现

| 要查的内容 | 唯一维护位置 |
| --- | --- |
| 采用哪个方案、完整 PPA 和退化 | [选型记录](../verification/ICACHE_SELECTION_2026-09-21.md)、[决策 JSON](../verification/data/icache-selection-20260922/decision.json) |
| 每个配置与每项负载的数值 | [配置 CSV](../verification/data/icache-selection-20260922/configuration-results.csv)、[逐项 CSV](../verification/data/icache-selection-20260922/case-results.csv) |
| 原始日志路径、大小和哈希 | [日志索引](../verification/data/icache-selection-20260922/raw-log-index.json) |
| 正确性和回归范围 | [最终验证](../verification/data/icache-selection-20260922/final-validation.json)、[验证协议](../verification/data/icache-selection-20260922/validation-protocol.json) |
| 电路与状态更新 | [替换器说明](../microarchitecture/ICACHE_REPLACEMENT_DESIGN.md)、[替换器 RTL](../../vsrc/riscv32/core/frontend/riscv32_icache_replacement.sv) |
| 模型、负载与独立验证 | [C++ 模型](../../tools/icache_explore/model.cpp)、[负载构建](../../scripts/build_selection_workloads.py)、[替换测试](../../scripts/test_selection_replacement.py) |
| 完整复现流程 | [复现脚本](../../scripts/reproduce_icache_selection.py)及[选型记录中的命令与依赖](../verification/ICACHE_SELECTION_2026-09-21.md) |

学习时先核对现有结果，再按选型记录使用新目录运行小范围模型/替换测试；完整综合矩阵
会耗时较长。修改源码后产生的是新的实验，不得覆盖冻结结果或将新程序挂到旧哈希名下。
复现脚本和各阶段已有验证，不表示每次补文档都重新跑过整套综合与仿真。

后续每项研究继续保留：问题与事实、原文及版本、适用前提、可检验假设、简单对照、
电路代价、验证结果、采用或拒绝原因、退化场景和未完成项。完整数据留在验证记录，
学习笔记解释设计依据并链接证据，避免在多个文档复制同一份结果表。
