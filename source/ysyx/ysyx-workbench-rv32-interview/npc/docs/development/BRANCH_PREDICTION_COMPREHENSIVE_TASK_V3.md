# CPU 分支预测完整探索与实现任务书 V3

版本：2026-10-01。
仓库：`roundeodo/ysyx`；基础分支：`rv32-interview-20260911`。
任务制定时核验的分支提交：`fbe782468be84d92cc658246c30580bd9a4a18f6`。

**本文件完整替代 V2 的范围约束，不依赖先阅读 V2。** V2 的诊断、验证和可复现要求保留；不再把“只评估少数微调”“先不做 SC/loop”“先只做四个配置”当作完整任务的结束条件。

## 0. 总任务与执行原则

寻找并实现适合当前 RV32 CPU 的高性价比分支预测子系统，而不是仅比较方向表准确率，也不是预设 TAGE 或静态混合必须胜出。

必须联合考虑：

- 控制流指令识别：是否存在 branch/jump、是什么类型、何时知道。
- 条件分支方向：静态、动态，以及真正针对同一条件分支的静态/动态混合。
- 目标获取：BTB、直接目标计算、RAS、间接目标预测、分层/压缩目标存储。
- 预测时机：结果是否在有用的周期可用；快速预测、稍晚纠正、最终执行解析的关系。
- 状态生命周期：历史、RAS、查询快照、延迟训练、恢复、替换和失效。
- 实现代价：容量、读写端口、寄存器、组合路径、扇出、访问活动、总线占用以及整核时间。

交付必须包含调研、模型、RTL、验证、PPA、真实软件实验和取舍结论。不能只交付论文列表或计划；不能仅复述旧实验并结束；不能把所有方法全开作为唯一候选。

先读取真实源码、AGENTS.md、现有开发规范、计时规则、原始/现存研究记录及工作区差异。按实际工作区冻结新基线，不能把聊天中的数字或结构当成实时事实。

在不覆盖用户修改的独立本地分支/工作树执行。允许正常编辑、构建、测试和本地提交；不要擅自推送、合并远程分支或删除无关文件。危险清理、产品目标改变、外部付费资源等需单独确认；一般设计和参数选择自行完成。

## 1. 三类结果必须区分

1. **算法能力**：在明确定义的输入与训练时机下，预测正确率、错误分布、学习速度如何。
2. **集成有效性**：类型、方向、目标是否同时可用，预测是否及时被前端采用，实际减少了哪些可观察等待。
3. **硬件性价比**：考虑合法频率、面积和活动代价后，完成真实工作是否更有价值。

TAGE 比小 Bimodal 更准但整核不划算，并不矛盾；也不证明 TAGE 无用。完整参考的算法结果不能作为低成本缩放 RTL 的性能承诺。反过来，ISA 回归通过也不证明预测算法实现符合设计。

本任务寻求：最低成本候选、面积×时间最佳候选、预算内最低延迟候选。只有通过预先冻结验收条件的方案才建议成为默认。

## 2. 基线、边界与旧结论审核

### 2.1 主线系统固定项

首先按源码核对并冻结 `rv32-balanced`：RV32I/Zicsr/Zifencei，单发射顺序后端；I-cache 1 KiB/4 路/32 B/策略13；D-cache 256 B/2 路/16 B；基线 BHT16、BTB 总16项/2路、RAS4。若实际源码不同，记录差异并使用实际配置。

主线不同时扩大 I/D-cache、改变 ISA、增加 OoO 或发射宽度。前端必要的预译码、预测响应级、有限快照/目标队列可以探索，但全部作为显式硬件变量计费。需要改变 memory concurrency、cache banking 或接口时，应另列结构实验，不把它的收益全部归因于预测器。

### 2.2 必须核验的既有证据

- 旧历史研究使用小型三表 TAGE、已解析历史，固定小 BTB；不等于完整 TAGE-SC-L 或联合最优搜索。
- 旧目标研究的方向表较小；单项不获益不能排除交互收益。
- 原始结果曾从发布树清理。缺失日志/manifest/网表不能写成重新验证，必须重建。
- 旧正确路径模型忽略实际训练延迟和错误路径；其窗口初始状态与 RTL 未必相同。
- Python/C++ 原测试主要比较单一短前缀的聚合统计；并非逐事件全状态等价。
- TAGE 原模块 TB 检查预测及上下文；并非完整 counter/tag/useful 状态逐项等价。
- 原 AI 代理的输入、词表及调用图规模有限；旧 held 输入已被反复观察，应改称历史回归，不再作为本轮最终独立测试集。
- 原生 ysyxSoC delayer 和独立 AR 握手起点存储模型不是同一个环境，必须分开报告。

输出 `baseline_manifest`：commit、dirty diff、文件/软件镜像哈希、工具和标准单元库、编译参数、计时窗口、存储服务、当前合格频率。实验关闭配置须与稳定基线在相同镜像/频率下功能与周期一致。

## 3. 文献与命名要求

依据作者论文、正式出版物、官方文档和作者/官方 artifact。核验年份、发表类型、配置、代码版本和许可证，优先阅读 2023—执行日的新工作，同时保留有价值的经典对照。

每个机制提交一页以内研究卡：

`要解决的错误 → 使用的信息 → 信息何时可得 → 状态与端口 → 预测/训练/恢复规则 → 原文成本 → 本核改造 → 简单对照 → 可证伪假设`。

“完整 TAGE”必须指明具体作者版本和配置。至少区分：基础 TAGE、TAGE+loop（L-TAGE 类）、TAGE+SC、TAGE-SC-L、ITTAGE（间接目标）。TAGE-SC-L 不等于完整 CPU 前端，不自动包含 BTB/RAS，也不自动解决取指缺失。

允许完整作者软件实现作为算法参考。若缩减表数、历史、SC 特征或 loop 组织，名称标明“缩放/改造版”，逐项列出差异。不能在缺少正文或 artifact 时声称完成复现。

## 4. 方向预测探索目录：不能遗漏静态/动态混合

### 4.1 必须建立的简单对照

- 顺序取指/始终 NT：诊断下限，不假设其最省面积就是最优。
- 静态 BTFNT，JAL 单独按其 ISA 语义处理。
- Bimodal：包含现有16项及若干相邻容量。
- Gshare：独立变化表容量和历史长度，核验高/低位 XOR 约定。
- 有价值时增加 local history、bi-mode、tournament、YAGS/带tag例外结构或感知器作为模型对照；说明动态组件组合不等于静态/动态混合。

### 4.2 真正的静态/动态混合，至少建模以下四类

**H1：静态初始化/冷启动补充。** 已识别分支在未训练、无有效记录或 newly allocated 状态下使用 BTFNT/可信离线偏置；稳定后使用动态表。初始化发生于哪个可实现事件必须定义。无tag PHT 无法天然知道某个 PC 是否“第一次出现”，不能用 evaluator 的无限 PC 集合作为候选硬件。

**H2：置信度门控回退。** 动态预测可靠时使用动态，否则使用静态。先测 counter 强弱、provider 年龄/替换状态和实际准确率关系，再设门槛；计数器处于强状态不等于已经校准的可靠概率。动态误判但静态正确、反之以及二者同时错误都要统计。

**H3：静态偏置＋动态同意/反对。** 以 BTFNT 或冻结的离线偏置 `S` 为先验，动态表预测“结果是否同意 S”；最终方向由先验与 agree/disagree 组合。训练目标是 `actual_taken == saved_static_bias`，不是无条件用 taken 更新 agree counter。参考 Agree 思想但标清偏置来源与原论文差别。保存查询时的偏置；先验变更、索引碰撞、代码替换均需明确语义。

**H4：静态与动态的可学习选择器。** 同一条条件分支同时得到 static 和 dynamic 候选，chooser 仅在两者意见不同且能区分谁正确时按规则更新。独立计入 chooser 的tag/容量/别名/冷启动/训练状态；测 chooser 带来的正确覆盖和错误覆盖。

可补充静态先验＋tagged exception cache：仅为反复违背先验的上下文存储修正。若参考 YAGS，明确原 YAGS 的基础偏置是动态学习的，不能直接改名为静态算法。

**以下不算完成本节：** “JAL/JALR 总是 taken＋BHT”；复用早期 BTFNT 的旧结果；只写一个 fallback if 却不计 metadata 成本。

### 4.3 静态信息可用性是硬约束

BTFNT 需要当前分支的偏移/方向和类型。预测请求时只有 PC 时，不能从离线反汇编表免费取得这些信息。候选须选择并计费：BTB 中缓存 type/backward bit；I-cache 旁带预译码 metadata；取回指令后再计算；或有实际读取延迟/容量的只读软件提示区。

JAL 的 unconditional-taken 是 ISA 事实，不是 BTFNT 对条件分支的猜测。使用 PGO/静态 hint 属于 HW–SW 单列实验，配置文件/ROM/加载和失效不能免费；不默认给现有 RISC-V 指令加入未定义提示字段。

## 5. TAGE 系列：完整能力必须评估，但逐组件量化

### 5.1 完整软件参考

选择一份公开的 TAGE-SC-L 作者实现，冻结版本。原配置用于核验规则/观察算法潜力；至少建立可缩放的软件参考并明确与原实现的不同。不是要求将作者原始数十 KiB 预测器不加修改地塞进当前核。

完整参考必须能在应用轨迹上测量冷启动、稳态、分支类型和训练时序假设；不能称它为理论准确率上界，也不能以其结果替代缩放 RTL。

### 5.2 必须可拆分的候选功能

- base 表与 tagged 表容量独立；表数、历史长度组、tag 位数独立参数化。
- 查询的最长匹配、alternate、弱/新项选择（如 USE_ALT_ON_NA），区别于旧 PROTECT_ALTERNATE 的 useful 保护。
- counter、useful、分配数量与优先顺序、分配失败老化、周期/压力驱动老化。
- 全局方向历史、path history、局部历史与 loop 相关特征，不能混用定义。
- loop predictor：trip/current/confidence/age、溢出、变长循环、嵌套/重入及阶段变化。
- SC：读取哪些特征、每张表与加法宽度、饱和/阈值、选择/纠正和训练策略。证明何时推翻 TAGE，而非只把表相加。
- 历史折叠和增量更新，避免长 history 直接组合折叠成为未计入成本的关键路径。
- 选择性访问/小型分级结构：需要实测访问活动与延迟，不因“关门”名称就声称节能。

### 5.3 最低消融要求

对相同基底和定义，比较：

`TAGE core`、`TAGE+loop`、`TAGE+SC`、`TAGE+SC+loop`。

再分别比较 `resolved history` 与可恢复的 `speculative history`。包含旧小TAGE对照；标准参考、缩放参数、修正的选择机制不能一次全部改变而不解释收益来源。

不能以“太复杂”“面积肯定很大”作为跳过 SC/loop 建模和至少一组缩放 RTL 消融的唯一理由。若实际受工具或资源限制无法完成，要标记任务未完成，而不是用旧 T16 的负结果替代新实验。

### 5.4 哪些不是 TAGE 的保证

最长历史不保证更准；完整配置不保证每个程序胜出；SC 与 loop 不保证都提供净收益。硬件不知道源代码的语义类别，只能利用实际可获得的 PC、历史、计数和上下文统计。任何 learned selector 都可能选择错，必须测量。

## 6. 目标与控制流识别：不仅是扩大 BTB

以下候选全部需列入覆盖清单。每类先完成机制与机会诊断；有潜力的进入共同模型/RTL比较，不能只留下名词。

| 编号 | 方向 | 需要验证的核心问题 |
|---|---|---|
| T0 | 完整目标BTB容量/相联度/索引/替换/准入 | cold、未及时训练、替换和冲突分别占多少；扩容成本是否合理 |
| T1 | 小快速BTB＋第二级BTB/目标缓存 | 第一级迟/漏预测能否被第二级及时纠正；访问次数和多级override代价 |
| T2 | 取回指令后的直接目标计算 | 条件branch/JAL由PC+立即数得到目标，不依赖BTB hit；方向从静态或动态预测获得 |
| T3 | I-cache行预译码/旁带控制流metadata/选择性BTB预填充 | 更早识别分支、减少训练延迟；metadata成本、失效、污染、端口和关键字提前返回 |
| T4 | 压缩目标、delta/region编码、分离类型与目标 | 必须范围检查并有完整目标后备或明示回退；跨区/布局变化不能静默错误 |
| T5 | return识别＋RAS，包括不靠BTB命中的返回识别路径 | call/ret类型、深度/溢出、解析与推测更新、递归/协程提示、恢复 |
| T6 | 非return间接目标：last-target、path/history target cache、小型ITTAGE | 同PC多目标是否可被历史区分；tag/目标/置信度/更新成本 |
| T7 | 操作数就绪时提前解析JALR/branch、可选预计算 | 是实际计算而非统计预测；RF端口/前递/RAW检查、关键路径和错误恢复 |

T2 中读取当前指令后计算直接目标，是精确目标计算，不是又一个目标猜测；它可能比请求侧BTB晚，但仍早于EX。一般JALR不能仅靠立即数解码得到目标。RAS对应结构化返回；ITTAGE针对间接目标；二者不能简单代替所有BTB能力。

T4：旧 U16 跨64 KiB失去覆盖的现象必须有对应定向测试，不能只测试原小镜像布局。保持完整PC身份和正确性；采用partial tag时承认别名，最终EX校验不得删除。

T5：推测RAS回滚不能只假设恢复SP足够；push/overflow可能覆盖旧内容，必须保存恢复所需内容或采用能证明正确的组织。x1/x5调用返回提示按ISA和现有译码核验；普通JALR不自动当ret。

T3 与多级BTB中，预填充不是执行训练，不能使用未发生的真实taken结果。准入应考虑用过/偏置/置信度；否决或延迟预填充不能丢失必须完成的需求事务。

## 7. 预测时机、协调与历史：独立研究轴

对每个候选定义从 PC 请求到结果消费的逐拍契约：

1. 请求侧快速预测使用哪些当拍信息？
2. I-cache/第二级预测器返回后是否override，是否保留本条指令？
3. EX何时解析，何时产生真实训练事件？
4. 是否按每条指令还是每个fetch block更新历史？只有PC、尚未识别branch时如何处理？
5. 方向原始输出与最终采用方向不同，speculative history记录哪一个？
6. BTB漏掉的not-taken分支即使不改变PC，也可能需要补历史；不得仅靠PC redirect判断历史是否正确。
7. 分支目标恰好PC+4、非分支误识别、类型错误、target错误和direction错误如何区分？
8. early override、EX redirect、trap、mret、FENCE.I同时发生时，哪个更老，清除哪些状态？
9. 被清除的动态查询如何不再训练？已占用总线的旧请求如何排空而不是撤回VALID？

resolved、speculative、commit更新分别针对历史/RAS/学习表定义，不能一个“推测更新”同时代表三者。

正确但迟到的预测不一定有价值；更快但不准确的预测也可能拖累后级纠正。每个多级方案要统计早期正确被错误override、早期错误被正确修复、结果过迟、重复纠正与额外查询。

本轮允许有限前端解耦/目标队列，只要有独立基础结构对照且计入成本；不强制增加深FTQ、OoO或取指宽度来人为制造TAGE收益。

## 8. 一致的模型接口与信息隔离

推荐将旧大条件分支式脚本整理为统一驱动器＋独立预测器模块，但不为了重构破坏可复现性。Python作可读参考，C++作快速扫描，RTL作最终闭环测量。

建议事件接口：

```text
lookup(pc, available_metadata, dynamic_id) -> prediction, context
accept(prediction_context)                -> accepted event
resolve(dynamic_id, actual_type, actual_taken, actual_target)
train(saved_context, resolved_outcome)
squash(cutoff_or_epoch)
invalidate(reason)
```

具体可合并接口，但必须写清事件定义。`actual`在模型驱动器中作为评分/训练真值保存，候选lookup不得读取它。循环/静态策略需要target sign时，由指定阶段可得的信息提供；不能默认trace里所有字段在取指时都可用。

### M0：正确路径立即训练模型

用于大范围算法初筛，报告错误、学习曲线和逻辑资源；不输出CPU时间，不把静态分支已知身份的效果冒充真实请求侧预测。

### M1：延迟与投机事件模型

模拟query/accept/resolve/训练/回滚顺序，用于比较历史时机、迟到信息、stale entry和端口冲突。事件tick不冒称CPU cycle。固定基线的事件流不能重现候选改变后的错误路径，因此仅用于诊断/筛选。

### M2：真实RTL闭环系统

候选RTL实际驱动PC、取指、I-cache、队列、执行和恢复；Verilator完整运行同一软件镜像及存储环境。主性能结果只来自这一层。不得将B0 trace的cycle列拿来给新预测器评分。

### 作者参考与可实现预算分开

完整TAGE-SC-L作者软件可以作为机制参考；同预算候选需单独缩放。可选复用官方gem5/BOOM/作者artifact核验，而不是必须从零复制整颗CPU模型。比较时统一历史编码、更新次序、table参数和随机分配种子；合法的不同变体不要求逐位相同。

## 9. 工作负载：功能正确与代表性分别证明

### 9.1 三组输入不能混成一个分数

- **机制诊断/验证程序**：稳定偏置、交替/相关分支、变长循环、递归、多目标JALR、热点与冲突、phase change、错误路径副作用等。
- **目标应用软件**：实际CPU-side tokenizer/预处理、模型元数据/装载、runtime控制、后处理代码与有来源输入；原代理保留为一部分。
- **历史参照**：MicroBench和旧cpu-tests。新实验明确其用途，不拿一个程序家族的高分替代目标应用结果。

### 9.2 必须改进的代表性要求

至少引入两类有明确上游来源的实际软件片段，保持关键数据结构和调用路径。记录上游commit、许可证、裁剪/移植、输入来源、规模。仅把几行随机if冠名AI不合格。

词表/merge、输入长度、JSON嵌套/布尔/数字/Unicode、调用深度、图规模、NMS框数与类别要有覆盖表。特别检查旧 `stream=bool(seed&1)` 与全奇数seed的覆盖缺口。随机种子改变不保证语义类别改变。

资源放不下真实规模时：首先记录限制，尝试保持算法的数据结构并选择有代表性的子集；如果扩大仿真RAM，所有候选和基线必须用相同RAM并另列实验，不能静默更换系统假设。

为原代理与实际片段比较：代码/数据工作集、分支类型比例、taken偏置、静态PC复用距离、BTB覆盖、目标数/切换、call深度和冷热训练曲线。没有这项校准不能宣称已代表整个边缘AI领域。

### 9.3 软件构建与防泄漏

主硬件对照使用同一二进制、同一输入、同一参考结果、同一测量边界。需要PGO或代码布局优化时作为单列软件实验；其训练语料只用开发集，记录再编译造成的指令数量/地址变化。

输入生成、Python参考、native运行、RV32输出检查保留；结果hash不是零碰撞证明。检查hash/校验循环是否主导ROI，必要时将完整正确性校验移出计分区或单列开销，不允许因此被编译器删掉被测计算。

主评测至少有冷启动、自然跨调用稳态两个独立口径。所有预测器通过相同前缀自行预热，不能复制基线表状态；稳态不得只是无说明地重复同一小字符串。工作量到达状态收敛的程度用学习曲线说明。

预先划分开发、验证和最终保留集。旧held属于已知数据。可采用预先划分的留一家族验证辅助判断泛化；最终保留只做一次冻结验证，不在看完后修改方案再称其独立。

## 10. 诊断观察器与指标

使用不参与综合、不驱动候选控制的observer，记录足够宽的动态ID，不能仅凭PC或短frontend_tag认定同一动态实例。

至少包含：query/accept/early-decode/override/resolve/train/retire cycle，PC、epoch、实际类型、原始static/dynamic/provider方向、实际采用方向、各阶段目标及来源、actual_taken、actual_target、query-time历史与选择上下文、BTB hit/类型、cache事务状态。

实际taken来自执行比较信号；不能唯一用 `next_pc != pc+4` 推导。对target=fallthrough、JALR、异常边界均有测试。

### 10.1 错误分解

- 类型缺失/误识别：BTB miss、false positive、错误kind。
- 方向错误：实际条件分支，raw predictor方向对错与最终选择分别统计。
- 目标错误：BTB hit但目标错、RAS错、间接目标错、压缩范围不可表示。
- 及时性：正确结果到达过迟、快速路径被错误override、结果受反压不能及时消费。
- 历史/训练：漏掉历史、查询年龄、stale provider、端口冲突、训练等待、被丢弃训练。

交叉统计 `BTB hit/miss × raw direction correct/wrong × final next-PC correct/wrong`。BTB no-match总数不等于造成恢复的no-match数；动态JALR目标变化不是天然的BTB miss。

按PC/分支实例分析“基线错候选对”和“基线对候选错”，并关联当时缓存/总线状态。多个候选各自闭环时用正确路径动态提交序号对齐，不用相同绝对cycle对齐。

### 10.2 错误减少不等于时间减少：必须完成解释

至少区分：BTB屏蔽、目标来源不足、prediction latency、短恢复已被重叠、错误路径cache交互、I/D竞争、LSU/RAW停顿、Fmax下降、冷启动和输入阶段变化。

互斥周期分类用于描述，不等于可消除的因果损失；redirect到首次正确fetch不等于净执行时间损失；不能把所有错误乘固定penalty。

构造受控RTL干预：保持阶段和镜像相同，只改变一个诊断预测组件；检查退休轨迹/输出一致。oracle结果标明信息来自未来，仅在诊断配置使用，不进入候选/综合，不能默认各收益可加，也不能保证oracle对非单调cache交互是严格性能上界。

## 11. 实验组织：范围完整，避免盲目穷举

### 阶段A：重建与机会诊断

复现B0/B0关闭实验等价，建立事件观察器和新的负载分层。完成原Bimodal16/旧T16 × BTB16/BTB32四点对照作为起点，不作为终点。

### 阶段B：完整算法与静态混合筛选

建模第4节混合方案、基础动态对照和第5节TAGE/SC/loop系列。给出同预算曲线、冷暖行为以及分支分歧分析。分别控制算法容量与基础结构。

建议初筛方向组件预算点可取64/128/256/512/1024字节，保留原4字节BHT点；另测一份作者规模参考。数字是实验网格建议，不是产品预算。包含tag、u、selector、loop/SC、history；在途快照另列并计入全前端成本。

### 阶段C：目标与时机筛选

对第6节候选，至少比较：小BTB、合理扩容BTB、直接目标早期计算、两级/旁带metadata路线中的一种、RAS与非return间接路径。尚无应用收益的类别可以保留模型/诊断，但不得以旧目标表实验自动否决不同机制。

### 阶段D：强制联合试验，不能完全逐坐标优化

先用筛选出的代表点构造方向×目标获取二维矩阵。最低覆盖：

| 方向组件 | 现有BTB路径 | 容量/组织改善的BTB路径 | 小BTB＋早期直接目标/类型识别 |
|---|---|---|---|
| 最强合理简单动态 | 必测 | 必测 | 必测 |
| 最强静态/动态混合 | 必测 | 可按前两轮筛选 | 必测 |
| 缩放TAGE或TAGE-SC-L | 必测 | 必测 | 必测 |

加入真正有价值的RAS/间接目标增强。代表点筛选可降低开销，但必须保留主效应与交互；不能因某个方向组件在BTB16上输就不测试改善target后的组合。

不同方向在同一目标获取基础结构下比较；不同目标机制在同一方向组件下比较。早期BTFNT不能免费获得指令，稍晚动态结果不能假装同拍到达。

### 阶段E：系统敏感性与PPA

保持主默认系统，另列20/100/200ns级首响应、合理beat间隔、随机反压/固定多seed、不同布局与冷热状态。怀疑特定cache交互时单列诊断，不以偷偷扩大cache改变主结果。

包括原生SoC MicroBench回归；其delayer问题未修复时不合并进主性能结论。

### 阶段F：冻结与保留验证

开发/验证选定候选、预算和判据后写冻结manifest，再跑最终保留集。失败可否决候选或回退，不允许拿该保留集挑另一个赢家后继续称独立验证。

## 12. 最低RTL交付范围

除复现基线和合理简单对照外，本轮至少形成以下三类真实RTL成果：

1. **一个真正用于同一条件分支的静态/动态混合方案**，以及同信息时机/资源条件的纯静态和纯动态对照。
2. **一套可消融的缩放TAGE系列**，包括核心、loop、SC以及它们的组合；历史/alternate规则规范。至少一组实现中三部分均可真实启用，不能只有接口空壳或Python实现。
3. **一个不只扩大BTB的类型/目标及时性方案**，优先选择早期直接目标计算/控制流识别，或证据支持的两级BTB/旁带metadata机制，并完成与方向组件的联合RTL对照。

若代表性间接分支/返回负载显示足够的剩余代价，追加一项小型ITTAGE/路径目标缓存或RAS增强；若没有，交付机会和资源诊断，明确非本轮默认候选。

不要求全部文献方案都变成RTL。资源耗尽时留下完整进度与可恢复步骤，不能把未完成写成“所有方案都没价值”。不得在完成四点矩阵后就宣告整个任务结束。

## 13. 算法到RTL的等价与安全验证

### 13.1 软件参考必须先有独立规格

为每个模块定义query/train/override/invalidate/reset/squash的时序与优先级。Python和C++不能只是机械照抄同一个错误，须用作者实现、手算用例和独立表达方式校核。

不同配置在多个真实与定向输入上逐事件比较预测/选择上下文，再比較更新写集合和更新后的逻辑状态。只比较错误总数不合格。

### 13.2 模块直接驱动，不靠NEMU证明预测器等价

- 生成有序和延迟的query/train事件；以独立参考计算每次可观察输出。
- 在明确的采样边界检查组合结果，在时钟沿后检查更新状态；定义read-before-write或bypass契约。
- 核对完整base counter、有效tagged entry的tag/counter/u、allocation、aging、SC权重/阈值、loop计数和chooser、GHR/folded history；无效payload按规格屏蔽。
- 合成debug端口或bind观察器必须`ifdef`隔离，不改变正常综合配置；若内部组织不同则使用抽象状态映射而非强求物理逐位相同。
- 覆盖counter每个饱和边界、连续同址训练、读写同拍、snapshot过期、同PC多个动态实例、table replacement、weak-provider覆盖、selector被错误训练、static bias变化、loop溢出/变长、SC求和溢出与符号边界。
- reset/invalidate/training/lookup/flush同时事件均有确定性测试，记录优先级。
- 随机seed与参数多组运行，有功能覆盖计数和定向补足，不只报告运行周期数。

变异测试至少故意破坏：饱和、索引、history快照、useful、allocation bank、SC符号/阈值、loop退出、selector更新、RAS恢复中的适用项。说明哪些变异被检测、哪些未检测及原因。

有工具时对缩小参数做形式属性/有界证明：更新范围、优先级、响应稳定、取消身份不重复训练、历史恢复等。动态测试不能称形式证明，形式假设也不能掩盖真实接口问题。

### 13.3 全前端与整核集成

模块测试中人为生成“正确training context”不能证明CPU接线正确；另用实际DUT lookup/accept/resolve事件建立被动参考队列，核对同一动态ID的history、provider、选择结果和训练数据。

专门汇编/小程序覆盖：BTFNT例外、related/unrelated branch、branch target=PC+4、BTB冷/容量/冲突、JALR多目标、跨地址区目标、ret/嵌套/溢出、多个override、same-PC重入、随机反压、代码修改＋FENCE.I、错误路径store/MMIO。

保留现有fetch、FENCE.I、D-cache恢复、精确异常回归。D-cache独立单测用于确认自身行为，不冒称它单独覆盖了前端交互；交互场景放入整核TB。

NEMU DiffTest只验证该接口实际比较的ISA状态。审计具体比较字段，不宣称它自动比较全部CSR/内存/MMIO，也不要求NEMU实现TAGE。独立LSU/AXI监视器检查错误路径不可取消副作用。

预测准确率低但恢复正确仍可通过DiffTest；应用checksum一致也不证明表训练正确。上述层次均不能互相替代。

## 14. 性能与PPA的统一口径

每个主候选：真实RTL运行 → 周期/退休/流量；同流程综合 → 全核面积；完整STA → 合格频率；在该频率和相同物理ns存储服务下重新运行RTL。宿主仿真耗时和`$time`的固定测试单位不是CPU执行时间。

记录三组结果：

1. 相同信息/事件/预算下算法准确率与学习速度。
2. 共同合法频点下CPU执行时间，隔离频率影响。
3. 各自合法频点下执行时间、面积×时间和Pareto曲线。

`T_i = cycles_i / f_i`。主时间比先输入内配对，按冻结家族权重聚合；既报几何平均又报逐项和最差值。确定性同输入重复运行不是独立统计样本；随机存储测试采用配对seed，描述输入/布局敏感性。少量家族不声称普遍统计显著。

总成本包括方向表、tag、目标、static metadata、选择器、SC加法器、loop、历史、快照、RAS恢复、读写端口、pipeline/队列、时钟/复位/扇出缓冲。不能只数持久状态位。宏未使用就按标准单元实际成本，不用假想SRAM面积替换。

各候选采用相同合理综合/驱动修复努力；修valid-only reset、banking、更新门控时有等价对照。合法频率网格在近似并列候选处细化，但不越过未通过的setup/hold/gating。布局前结果不称签核；有P&R条件的最终点单列实测。

没有可靠功耗测量就仅报访问/翻转/流量代理，不能从面积推算瓦数或节能百分比。面积×程序时间不是能耗。

## 15. 选型规则：不预设赢家，也不让保守门槛阻止探索

- 本轮允许比较比默认贵的完整/缩放参考和结构组合。探索资格不等于默认启用资格。
- 默认继承整核面积×时间与单项时间退化≤3%的主判据；用户尚未给出新的硬面积上限，不凭空宣称“产品只能增加5%”。可提议分档预算并在看最终保留数据前冻结。
- 提交至少三种Pareto定位：最低额外成本、面积×时间最优、选定预算内最低延迟。解释不同部署目标的选择，不要求三个必然是不同设计。
- 不允许为了让TAGE/混合方案胜出而事后改变家族权重、加入合成相关分支高分或删除困难输入。
- 默认升级需要通过所有正确性检查、比最强合理简单对照有稳健净收益；若差异接近PPA/输入敏感范围，保留可选而非宣传普适最优。
- 不满足默认条件仍要交付已验证原型、适用场景和负结果。不能强行改变稳定预设。

## 16. 执行计划、资源与阶段进展

首次输出实际源码检查和执行计划，然后继续执行；不是每一步都等待用户挑参数。估算一次RTL构建/综合/运行成本，分阶段预算，优先共享相同二进制和已绑定的工作负载。

限制并发避免占满机器；只清可重建中间目录。失败命令保留日志，修正后追加结果而不是覆盖原失败证据。每个阶段更新：已完成、运行命令、通过/失败/未测、下一步、阻塞原因。

在资源范围内连续推进至模型、RTL与测量，不仅写计划。发生无法自行解决的许可证/权限/算力限制，准确报告缺什么及哪些证据尚无，不能伪造实验完成。

## 17. 最终文件与验收

建议结构（可结合现有规范调整，路径本身不是验收重点）：

```text
npc/docs/research/branch-v3/
  plan.md
  baseline-audit.md
  literature.md
  workload-provenance.md
  design-space.md
  candidate-contracts.md
  verification.md
  decision.md
  results-schema.md
npc/tools/branch_v3/               # 公共事件/驱动与各策略模型
npc/tests/branch_v3/               # 模块、集成、汇编/软件测试
npc/result/branch-v3/<run-id>/     # 不纳入大对象Git，但保存证据索引
```

必须交付：

- 有来源的候选覆盖表：已阅读、已建模、已RTL、已验证、已PPA、被淘汰或未完成。
- 静态/动态四类混合的模型对照，以及至少一类实际RTL闭环结果。
- 一份完整TAGE-SC-L作者参考的核验结果，缩放实现及TAGE/SC/loop消融，不把未实现部分写成已启用。
- BTB之外目标/识别路线的实际RTL，以及方向×目标联合试验。
- 为什么准确率变化没有按比例变成时间收益的逐类证据，而不是只重复“内存瓶颈”。
- 分层验证：模型、模块全状态、全前端身份、微架构安全、ISA、应用输出；每类列实际覆盖。
- 统一口径的同频/各自频率数据、面积、最差输入、Pareto和冻结决策。
- 至少一个候选给出从某次query、context保存、resolve训练、early/late redirect到退休的具体数值案例，便于用户学习。
- 可重新构建的配置、输入、脚本和命令；保存关键原始日志、工具/源码/镜像/结果哈希。不能只留结论后删除全部依据。

完成意味着三个必做RTL方向与联合比较已结束，或精确标明未完成；“没有赢家”可以是科学结论，但必须有本轮新实验，不是借用旧实验提前终止。

## 18. 源码阅读入口

以下路径在所核对版本中存在；执行时再次确认，不把历史 result 路径当作还存在：

- `npc/docs/verification/BRANCH_HISTORY_EXPLORATION_2026-09-24.md`
- `npc/docs/verification/BRANCH_TARGET_EXPLORATION_2026-09-23.md`
- `npc/docs/verification/MICROBENCH_TIMING_RULES.md`
- `npc/scripts/build_selection_workloads.py`
- `npc/scripts/build_branch_workloads.py`
- `npc/tools/branch_explore/direction_model.cpp`
- `npc/scripts/model_history.py`
- `npc/scripts/model_history_timing.py`
- `npc/scripts/test_history_cpp.py`
- `npc/scripts/test_tage_rtl.py`
- `npc/tests/rtl/riscv32_tage_contract_tb.sv`
- `npc/tests/frontend_exploration/core_tb.sv`
- `npc/vsrc/riscv32/core/frontend/riscv32_bht.sv`
- `npc/vsrc/riscv32/core/frontend/riscv32_tage.sv`
- `npc/vsrc/riscv32/core/frontend/riscv32_branch_predictor.sv`
- `npc/scripts/verify_branch.py`
- `npc/scripts/verify_direction_difftest.py`
- `npc/scripts/explore_history.py`
- `npc/scripts/finish_history_study.py`

## 19. 一手资料入口与核验范围

下列是研究入口，不是把所有方案列为已复现。实施时固定实际下载/代码版本、许可证并补充新文献。这里不提供任何论文收益在本核可复现的保证。

**TAGE/SC/loop：**
- André Seznec, *TAGE-SC-L Branch Predictors Again*, CBP 2016。本文是竞赛论文；其结构由TAGE、SC、loop组成，作者也明确区分比赛准确率配置与现实实现组织。
  https://jilp.org/cbp2016/paper/AndreSeznecLimited.pdf
  作者代码入口：https://jilp.org/cbp2016/program.html
- BOOM backing predictor：方向可以结合I-cache返回后的快速译码使用；历史、训练和恢复有各自的时机。不要把文档中的某一BOOM版本当作本核直接规格。
  https://docs.boom-core.org/en/latest/sections/branch-prediction/backing-predictor.html

**间接目标：**
- André Seznec, *A 64-Kbytes ITTAGE indirect branch predictor*, JWAC-2/CBP 2011。用历史相关的tagged目标表，区别于方向TAGE。
  https://jilp.org/jwac-2/program/cbp3_07_seznec.pdf
  作者代码入口：https://jilp.org/jwac-2/program/JWAC-2-program.htm

**经典偏置/例外/混合：**
- Sprangle et al., *The Agree Predictor: A Mechanism for Reducing Negative Branch History Interference*, ISCA 1997。作者列表入口已核验；本任务制定时正文链接访问失败，实施者须从可信源取得正文后核对偏置和训练细节，不得声称此处已完成逐算法复现。
  https://hps.ece.utexas.edu/hps_branchpred.html
- Eden and Mudge, *The YAGS Branch Prediction Scheme*, MICRO 1998，DOI 10.1109/MICRO.1998.742770。作为需要进一步取得原文核验的候选；不要用未经核实的第三方教学实现代替原始规则。

**近期目标/时机与能效研究：**
- *Look Before You Leap: Precision Instruction Supply via SmartScout*, ICS 2026。作者介绍中的机制是运行时过滤BTB预填充噪声与利用FTQ时机提前纠错；不能把其多级/解耦前端前提删除后照搬性能数字。
  https://craft.cs.tsinghua.edu.cn/publication/look-before-you-leap-precision-instruction-supply-via-smartscout/
  https://doi.org/10.1145/3797905.3815060
- *MORSL: Minimal-Overhead Rank-Based Predictor with Summation-Free Correction and Lazy Access*, CBP-NG 2026（与ISCA同期的竞赛，不是ISCA主会论文）。核验作者PDF和代码，研究访问组织，而非只复制容量。
  https://www.rsg.ci.i.u-tokyo.ac.jp/lab/en/papers/2026/
- *RUNLTS: Branch Prediction with Register-Value Correlations and Hierarchical Table Orchestration*, ISCA 2026。值相关只在实际可用信息上建模，不能读取未来EX操作数；作为扩展研究方向，不强制完整RTL移植。
  同上作者资料页。
- *Enabling Ahead Prediction with Practical Energy Constraints*, ISCA 2025。用于分析预测器自身延迟和访问代价；是否适用由本核前端时序决定。
  https://hps.ece.utexas.edu/hps_branchpred.html

仓库已有BTB-X等来源继续核验并复用；不能因参考老算法就否定其性价比，也不能因论文新就省略强基线。
