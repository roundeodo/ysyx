# RV32 前端探索：计划与结果

状态：完成本轮限定范围的探索、实现和验证；实验分支 `frontend-exploration-20260921`，不推送、不合并。
任务依据：[任务书](../development/FRONTEND_EXPLORATION_TASK.md)。

## 冻结基线

本地 `47c852e` 与远程 `e3b018f` 的 NPC 内容一致。原有 am-kernels、ysyxSoC
依赖补丁保留；用户提供的任务文件不修改。快照、diff、工具与配置记录在
`npc/result/frontend-exploration/20260921/baseline/manifest.json`。
RV32I/Zicsr/Zifencei 顺序核；I-cache 256 B/1-way/16 B、D-cache 256 B/2-way/16 B，
BHT 16、BTB 16/2-way、RAS 4。沿用三项异常恢复修复。历史 STA 通过点 580 MHz；
新候选独立测量，历史数据不冒充本轮重测。无 L2、MMU、并发 I-cache miss。

## 预先固定的实验约定

- 主要指标：等权负载执行时间比的几何平均；面积约束为全核映射单元面积。
- 采纳门槛：相对最强简单对照，时间比 <=0.97，面积相对 B0 <=1.05，
  每个保留负载时间比 <=1.03。没有达标方案则保持正式默认配置。
- 第一轮预算：最多两类深入候选；表/元数据增量先限制 512 bit，
  容量对照可用相同总成本替换，不把队列、tag、有效位排除在成本之外。
- CPU 代理负载：整数词法/token 查表、INT4 解包/后处理、runtime 命令调度。
  不代表完整 AI 模型，不扩大 ISA。每类固定开发输入和不同分布/规模的保留输入。
- 开发种子 11/23；保留种子 101/307。开发小规模，保留较大规模或不同阶段，
  不是相邻 trace 切片。最终参数冻结后才运行保留集。各类等权，MicroBench 单独报告。
- 冷复位起跑，初始化在统计窗口外；窗口内重复调用，包含自然预热，不预先填表。
  独立 Python 参考生成期望输出；固定链接脚本、镜像与 ELF 哈希。
- 同频先按 580 MHz。除历史 SoC 对照外，建立从握手开始、服务延迟有明确周期定义的
  共享 I/D 总线参照模型；使用探针核验早呈现 valid 不增加握手后延迟。
  模型变化独立计账，不归因于硬件优化。观察器只读且开关对照。
- 停顿使用互斥优先级分解，事件另列；退休 trace 只做容量/策略筛选，
  错误路径流量、及时性和最终周期必须通过 RTL 获取。

## 执行次序

1. 基线相关回归；建立代理负载、独立校验、被动观测和可信参照存储模型。
2. 测工作集、冲突、暴露取指等待、分支错误、预测距离及 I/D 竞争；据此选择主方向。
3. 核验近年作者论文和 artifact，记录系统前提、资源与本核改造；模型筛选 2～3 类。
4. 固定 B0、合理扩容/调参 B1、必要基础结构 B2、同基础结构简单策略 B3 与候选 C。
5. 先写电路/状态说明，再写可配置 RTL；单项先测，有价值才组合和消融。
6. 正确性回归、综合/完整 STA、同频与合法频点时间、流量和敏感性比较。
7. 冻结参数后按预定矩阵运行保留集；交付原始日志索引、机器结果及采纳/拒绝结论。

## 当前进度

已读取规范、负载目标、计时限制和实际前端连接，完成基线源码冻结。
已完成七组 RTL 对照、开发/保留输入、延迟敏感性、正确性、综合和四组 STA。
结论：保留默认基线，退休反馈作为关闭的已验证原型，不建议默认启用。完整数据见下文。

## 开发集首次诊断与方向选择

共享总线参照环境中，tokenizer 的前端空供给占 64.7%/66.5%，runtime 占 83.3%/83.5%；
INT4 仅约 7.2%，数据等待约 29%。这些是互斥周期桶，分支/缓存事件不能再相加。
开发集每类两输入；观测开关的输出、周期、退休和摘要完全一致。独立探针验证提前展示
ARVALID 而保持同一握手时刻，不改变首 beat 及后续 beat 的服务时刻。

退休轨迹模型显示：runtime 的直接映射冲突明显，256 B 两路 FIFO 将模型 miss 从
812/818 降到 44/44；但 tokenizer 从 1501/1508 增到 1952/2030，不能只报告好例子。
512 B 简单扩容在模型上很强，必须保留为成本对照。INT4 几乎没有容量优化空间。
模型不计错误路径和交错回填，数字不是 RTL IPC。据此确定主方向为 I-cache 管理；
不新增预取并发，避免把服务机会和身份管理的基础设施收益包装成策略收益。

本轮深入实现的候选：借鉴 Bumper 的“退休确认后提高保留优先级”，迁移到两路小型 L1I，
不是复现原论文的 L2 方案。其适用性需要通过真实退休/取指时间的筛选及 RTL 验证；
候选可能因低错误路径污染、提示迟到或额外读口成本而失败。
对照：B0 单路256；B1 两路256 FIFO，以及单路512容量成本对照；
B2 两路256 SRRIP（插入2、命中0）；B3 相同RRPV结构插入3、命中0；
C 插入3，仅退休或已确认行的命中提升。参数全局固定，不按程序挑选。

## 文献核验与改造边界

检索截止日期 2026-09-21。以下仅说明影响本轮决定的机制，未复制作者实现代码。

| 工作与一手来源 | 原始前提/资源 | 本轮决定 |
| --- | --- | --- |
| [Bumper，ISCA 2026，作者稿](https://www.pure.ed.ac.uk/ws/portalfiles/portal/654859698/VavouliotisEtalISCA2026Bumper.pdf) | 620项ROB、16宽fetch、192 KiB/6路L1I、6 MiB/12路统一L2、64 KiB TAGE；422 B是新增提示传递状态，不是整套缓存成本。L2插入RRPV=3，退休命中提升0，普通hit只有RRPV<3才提升 | 仅借鉴退休确认；直接反馈小型物理L1I，去掉地址翻译、跨层提示队列和FDIP前提。不复制论文收益；迟到/未驻留提示会丢失，必须计数。本轮模型改善弱，RTL验证可能得负结果 |
| [Wrong-Path-Aware Entangling，IEEE TC 2024，作者稿](https://webs.um.es/aros/papers/pdfs/aros-tc24.pdf)；[作者artifact](https://github.com/alberto-ros/EntanglingInstructionPrefetcher/tree/main/TC-24) | 320项ROB、32 KiB/8路L1I、1 MiB L2、深FTQ；4K关联表和历史，优化版含FTQ约41.87 KiB。错误路径训练需按恢复撤销；artifact仓库标明CC0 | 不实现整套关联预取。当前阻塞L1I没有可同时服务的第二miss，先增并发会超出本次策略归因范围；工作集冲突已有更低成本的简单对照 |
| [SmartScout，ICS 2026，正式出版页面](https://doi.org/10.1145/3797905.3815060) | 可读取的出版索引描述TAGE置信度过滤、FTQ在途纠正、服务器BTB容量瓶颈；18 KiB扩容对照以及1K直接/2K返回预填充缓冲 | 不把它缩成16项BTB上的同名实现。本轮没有TAGE、深FTQ与行预解码；完整页面访问403，artifact尚未核验，不能声称完成复现或依其百分比预测本核收益 |

Bumper 作者稿给出工业模拟器方法，文中未发现artifact说明；未取得可验证公开代码。
本轮的退休反馈RTL由已有接口独立实现，不存在复制代码后的许可证依赖。
SRRIP是经典简单对照，不属于新方法。实验不报告瓦特、pJ或每token能耗；只报告表访问、
反馈匹配及总线beat等活动代理量。

额外检索到 [TRRIP，MICRO 2025作者预印本](https://arxiv.org/abs/2509.14041)：
该方案依赖编译器温度分类、代码重排和OS页属性，不是纯在线硬件热点计数。
本轮固定镜像且无MMU，不新增PGO/页属性轴；因此不将其包装成一个简单计数器移植。
经典SRRIP依据 [Jaleel等ISCA 2010作者稿](https://jaleels.org/ajaleel/publications/isca2010-rrip.pdf)。

原型调试中发现观察器不能把4值frontend_tag当作覆盖后端的全局指令身份。
已改为旁路跟随预测响应、唯一在途请求、fetch buffer和执行寄存器的真实握手；
身份断言保留，失败日志不删除。DUT的事务身份和epoch规则没有修改。
最终计数窗口定义为(begin标记退休,end标记退休]，end的NOP同时计入周期与退休。
早期诊断缺少该末端周期的分类，保留原始记录；最终表只使用新观察器结果。

## 综合资源约定更新（保留集评分前）

原DELAY 0流程的本轮基线映射超过20分钟；准备停止时已完成且580 MHz全组通过，
保留该补充结果并停止后续重复配置。为控制探索成本，所有主比较改用仓库已有AREA 3策略、同一NanGate45库、
同一约束与复位边界；基线也重做。门槛仍为5%/3%/3%，不调整。
这套PPA只在本轮同口径方案间比较，不与历史DELAY 0面积直接计算优化收益。


## 最终实现与消融边界

只深入实现 I-cache 替换管理，未新增预取、并发 miss、推测 RAS/GHR 或预测器流水级。
核心通过已有退休端口提供 valid/PC；tag 阵列持有并更新 RRPV，I-cache 在原 S1
读取快照并选 victim。当前接口和时序见[I-cache 说明](../microarchitecture/ICACHE_DESIGN_RECORD.md)。

| 配置 | 改变与归因 |
| --- | --- |
| B0 | 冻结基线，256 B / 1路 / 16 B行；无替换状态 |
| B1 | 256 B / 2路 FIFO；仅增加相联选择能力，是替换实验的必要基础结构对照 |
| B2 | 同容量/相联度，SRRIP：插入2、所有hit提升0；经典策略对照 |
| B3 | 与候选相同RRPV结构，插入3、所有hit提升0；简单策略对照 |
| C | 插入3、退休匹配提升0、只有RRPV<3的hit提升；退休反馈候选 |
| capacity | 512 B / 1路 / 16 B行；容量成本对照，不假定免费扩容 |
| line32 | 256 B / 1路 / 32 B行；空间局部性与带宽代价对照 |

本轮没有预取队列或新增并发，因此任务书中的“仅基础结构”由 B1 承担，不另造无效寄存器。
B1→B2→B3→C 分别隔离相联度、RRIP、插入值和退休确认规则；没有组合两个独立方向。
C 的退休提升与条件hit提升共同定义确认规则，本轮没有声称已单独识别这两个子规则的贡献。

两路256 B共16行，RRPV为32 bit，同步快照4 bit；相对两路FIFO的8 bit指针，
新增替换状态28 bit。C与B3状态位数相同，但C增加退休tag比较及更新选择，面积不能只按位数算。
提示命中已有tag存储，不复制地址表；额外组合读/比较不是免费的SRAM端口。
回填完成前的退休提示可能丢失；C开发tokenizer约4.1%～4.4%的退休事件当时不驻留。
不新增提示队列是明确的成本取舍，未声称所有退休都能训练替换状态。

## 最终结果

数据：[机器可读汇总](../../result/frontend-exploration/20260921/summary.json)，
[原始证据索引](../../result/frontend-exploration/20260921/raw-index.json)。
最终表仅使用 `final-results`。所有代理输入的独立校验结果、完整程序退休摘要及退休数一致。

面积为 NanGate45、AREA 3、820 MHz综合目标、包含复位缓冲的纯核映射单元面积。
运行频率是同一网表按20 MHz步长检查的通过点，搜索上界800 MHz；B0/capacity抵达上界，
不能称为精确Fmax。各点同时检查数据setup/hold、时钟门控setup/hold及原始VIOLATED标记。
没有布局布线、布线寄生或芯片实测。不同频率重新运行RTL，外部服务保持100 ns首beat、
10 ns后续beat，不将580 MHz周期数直接除以新频率。

下表时间比越小越好；每类两个输入，六个输入等权。分母是相同实验口径下的B0。

| 配置 | 面积/µm² | 通过点/MHz | 开发集同频时间比 | 保留集同频时间比 | 保留集各自频点时间比 |
| --- | ---: | ---: | ---: | ---: | ---: |
| B0 | 69939.1 | 800 | 1.0000 | 1.0000 | 1.0000 |
| B1 | 70382.8 | 700 | 0.6693 | 0.6264 | 0.6404 |
| B2 | 70905.5 | 700 | 0.6634 | 0.5918 | 0.6025 |
| B3 | 70860.3 | 680 | 0.6519 | 0.5874 | 0.6071 |
| C | 71820.8 | 620 | 0.6662 | 0.5821 | 0.6330 |
| capacity | 81517.6 | 800 | 0.3845 | 0.3409 | 0.3051 |
| line32 | 68384.1 | 780 | 1.0127 | 1.0164 | 1.0260 |

开发集在预算内选出的最强简单对照是B3；保留集不参与选择。C同频开发集比B3慢2.19%，
同频保留集只快0.90%，未达到3%门槛。按各自通过点，C保留集比B3慢4.27%，
最坏输入慢6.63%；面积比B0增加2.69%，比B3增加1.36%。新方法未胜出。
B2在各自频点的保留集也略优于B3，但不会事后据此改选开发对照；这也不支持采纳C。

同频保留输入逐项列出，避免几何平均掩盖退化：

| 输入 | B0周期 | B3周期 | C周期 | C IPC | C/B3各自频点时间比 |
| --- | ---: | ---: | ---: | ---: | ---: |
| tokenizer-held-101 | 327669 | 376446 | 366178 | 0.1835 | 1.0082 |
| tokenizer-held-307 | 333987 | 390006 | 378930 | 0.1746 | 1.0064 |
| int4-held-101 | 103155 | 103155 | 103155 | 0.5625 | 1.0663 |
| int4-held-307 | 103255 | 103255 | 103255 | 0.5620 | 1.0663 |
| runtime-held-101 | 490535 | 88821 | 88435 | 0.3829 | 1.0489 |
| runtime-held-307 | 503193 | 85123 | 85664 | 0.3964 | 1.0621 |

B3相对B0的同频runtime保留输入时间减少约82%，主要来自相联度减少冲突；
tokenizer却回退约15%～17%。不能以runtime单项收益推荐全局默认切换。
512 B容量方案各项更强，但全核面积增加16.55%，超出预设5%；32 B行降低tag开销，
却增加runtime冲突及传输字数，保留集综合更慢。因此两者均作为成本/退化证据保留。

## 流量、分支和存储敏感性

同频保留集统计窗口内，I侧接收beat数：B0=68524，B3=31186，C=30082，
容量512 B=706，32 B行=111388。这些是需求及错误路径取指产生的流量，没有预取流量。
C相对B3少3.54%的I侧beat，但没有形成合格频点下的执行时间优势。
beat按窗口实际握手计数，首尾可能落在burst中间，所以不必恰好等于miss数乘行字数。
各输入D侧beat、请求等待、查询次数、退休驻留提示、分支错误分类均在summary及原始结果中。
未测功耗，不能由访问数直接换算能耗收益。
没有预取，故及时/迟到预取及未使用预取淘汰指标不适用。普通驻留行的未使用淘汰数
仅在筛选模型中估算，未单独作为RTL事件计数；不以该模型数字声称减少了真实错误路径污染。

分支错误分类使用随真实握手传递的查询上下文，BTB无匹配、方向错、目标错互斥；
条件分支/间接跳转/返回计数另作子集，不能再相加。C开发runtime每个输入约233次目标错误，
其中返回错误226次，说明缓存冲突改善后仍有预测空间；本轮未据此追加推测RAS修改。
“预测查询到需求查询握手距离”包含阻塞等待，不是预取及时性或可节省周期数。

敏感性保持输入、参数和580 MHz不变。下表为C/B3保留集时间几何平均比：

| 首beat/后续beat | 反压 | C/B3 |
| --- | --- | ---: |
| 20 ns / 10 ns | 无随机 | 0.9930 |
| 200 ns / 20 ns | 无随机 | 0.9900 |
| 100 ns / 10 ns | 固定种子随机 | 0.9908 |

三种条件都未达3%收益门槛。随机反压使用97531固定种子，属于本轮覆盖而非统计置信区间。
共享I/D总线、独立参考校验和握手服务起点固定；没有用变化的访存模型制造策略收益。
退休trace模型的instant-fill和固定B0事件时序只用于筛选，最终性能来自RTL。
模型中的320 B/4路条目仅为非RTL容量诊断，实际RTL参数要求合法几何，未实现或宣称该配置通过。

## MicroBench与计时

运行原生ysyxSoC MicroBench **test**，580 MHz、设备等效100 MHz、mtime为1 MHz。
程序保持原生定时器调用；观察器从仿真侧读取退休信息，无软件CSR插桩。
Total/Scored使用定时器读数对应的同一退休窗口，IPC=窗口退休数/窗口周期数。
三个配置的bin/ELF哈希一致，每个配置观察器开关的完整审计一致。

| 配置 | Total原生时间/ms | Total周期 | Total IPC | Scored原生时间/ms |
| --- | ---: | ---: | ---: | ---: |
| B0 | 5.987 | 3472296 | 0.220134 | 2.626 |
| B3 | 5.595 | 3245042 | 0.238390 | 2.535 |
| C | 5.658 | 3281714 | 0.235731 | 2.505 |

原生定时器有1 µs量化，Scored是多个子区间的和。其延迟器仍有请求呈现时刻敏感性，
因此作为软件参照与回归，核心机制结论使用独立握手计时的参照环境。
代理负载时间是指定模型下的C/f，不是ysyxSoC定时器读数，也不是端到端AI延迟。
本轮未运行train、RT-Thread、完整模型推理或功耗测量；不得用test比例外推train成绩。

## 正确性与验证边界

- 基线先完成fetch、84项核心恢复、10项FENCE.I控制、75项缓存恢复回归。
- C配置：上述回归再次通过；精确异常40/40、DiffTest35/35、中断8项均通过。
- I-cache契约：主配置19项；另测单组32 B/2路/16 B、256 B/4路/16 B、32 B/2路/4 B单字行。
- 新替换单元：三种非零策略及单组边界，覆盖旧/新tag提示、安装同拍旁路、提示迟到、
  miss老化、受阻快照、复位与失效优先级。服务探针覆盖100/500/580 MHz，
  ARVALID早晚呈现但AR握手相同的六种情形。
- 所有42个开发、42个保留同频代理运行，以及各自频点、54个敏感性运行均校验输出和退休摘要。
- NPC/SoC lint通过；保留已有struct级UNOPTFLAT警告，系统位级Yosys检查为0 SCC、0问题。
  RV64默认配置仅做lint兼容检查，不声称完成RV64功能验证。
- 新增机制不发总线请求，不改变epoch、tag、响应配对、FENCE.I排空、fatal停止或dirty-victim保护。
  故不存在新增“预取与维护并发”测试对象；原有恢复/反压/错误测试仍开启断言。

本轮失败记录保留：最初软件生成的预处理结尾错误、观察器误用4值tag造成身份断言失败、
首次lint继承旧NPC_HOME路径。分别修正生成器/旁路观察器/命令环境后重跑；未放宽DUT断言
或更改期望输出。初始DELAY 0映射耗时记录与AREA 3主结果分开，未冒充RTL失败。

## 设计决定

- **选择**：交付可选RRIP与退休反馈RTL、固定代理负载、参照存储模型、被动观察器及复现实验。
- **默认**：仍为B0，`NPC_ICACHE_REPLACEMENT_POLICY=0`。两路与容量变化也不自动启用。
- **拒绝默认采纳C**：同频收益没有达到门槛，新增替换状态的综合实现降低通过频点。
  C在620 MHz的数据关键路径实际从下降沿复位释放寄存器出发，经复位分配和更新选择到RRPV，
  只有半周期预算；不是已经证明退休PC比较器本身最慢。该工程实现成本大于已观察到的收益，
  也不能据此否定所有退休反馈电路。B3的限制路径同样涉及复位释放到I-cache有效位。
- **拒绝本轮完整关联预取/BTB预填充**：本核缺少论文要求的深FTQ、并发服务能力和大容量预测器，
  先加这些结构会扩大资源与验证范围，而现有冲突已有更低成本对照。
- **适用范围**：B3可作runtime冲突明显时的专用选项；不能忽略tokenizer退化。
  INT4主要受算术、循环和数据等待限制，I-cache替换基本无收益，降低频率反而损失时间。
- **下一次研究依据**：若扩大预算，先比较容量；若研究返回预测，使用本次剩余目标错误作为测量起点。
  这些是后续方向，本轮没有实现或宣称其收益。


## 复现入口

以下命令从工作树根目录运行。`run`可直接复用归档二进制，工具版本、脚本快照及库/工具SHA256见`toolchain/manifest.json`。完整重建需Verilator、
RV32交叉工具链、Yosys/slang、仓库NanGate45与iEDA工具目录。
`git_commit=`禁止课程Makefile自动提交；所有输出使用新目录，不覆盖旧证据。

```bash
export NPC_HOME="$PWD/npc"
export AM_HOME="$PWD/abstract-machine"
export NEMU_HOME="$PWD/nemu"
EXP="$PWD/npc/result/frontend-exploration/reproduce-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$EXP"
# 性能复现复用同一冻结RTL的基线和正确性档案；下方另列重跑回归入口。
ln -s "$PWD/npc/result/frontend-exploration/20260921/baseline" "$EXP/baseline"
ln -s "$PWD/npc/result/frontend-exploration/20260921/correctness" "$EXP/correctness"
python3 npc/scripts/explore_frontend.py images --output "$EXP/images-v2"
python3 npc/scripts/run_frontend_matrix.py --root "$EXP" --phase dev
# 使用本轮已冻结参数与源码校验；若源码不同会失败，不静默换基线。
cp npc/result/frontend-exploration/20260921/selection-freeze.json "$EXP/selection-freeze.json"
python3 npc/scripts/run_frontend_matrix.py --root "$EXP" --phase held
python3 npc/scripts/explore_frontend_ppa.py --output "$EXP/ppa-area3"
python3 npc/scripts/qualify_frontend_frequency.py --root "$EXP/ppa-area3" \
  --configs B0 B1 B2 B3 C capacity line32
python3 npc/scripts/run_frontend_qualified.py --root "$EXP" \
  --configs B0 B1 B2 B3 C capacity line32
python3 npc/scripts/run_frontend_matrix.py --root "$EXP" --phase held \
  --configs B0 B3 C --latency-ns 20
python3 npc/scripts/run_frontend_matrix.py --root "$EXP" --phase held \
  --configs B0 B3 C --latency-ns 200 --beat-ns 20
python3 npc/scripts/run_frontend_matrix.py --root "$EXP" --phase held \
  --configs B0 B3 C --random-stalls
python3 npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 580 \
  --verify-observer --output "$EXP/microbench/B0"
python3 npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 580 \
  --icache-ways 2 --icache-policy 2 --verify-observer --output "$EXP/microbench/B3"
python3 npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 580 \
  --icache-ways 2 --icache-policy 3 --verify-observer --output "$EXP/microbench/C"
python3 npc/scripts/summarize_frontend.py --root "$EXP"
```

默认关闭配置的开发集周期/整程序摘要已与修改前冻结RTL对齐，记录在
`baseline/default-off-equivalence.json`。若要重建原始RTL，可向`explore_frontend.py build`
传入`--rtl npc/result/frontend-exploration/20260921/baseline/source/npc/vsrc/riscv32`。
模型初筛入口为`model_frontend.py --traces <退休轨迹目录> --output <新JSON>`。

主要正确性入口：

```bash
make -C npc git_commit= NPC_CONFIG=rv32-baseline \
  NPC_ICACHE_WAY_COUNT=2 NPC_ICACHE_REPLACEMENT_POLICY=3 \
  test-icache-replacement test-icache test-fetch test-fence-i test-fence-i-ctrl \
  test-dcache-recovery test-precise-exception test-timer-interrupt
make -C am-kernels/tests/cpu-tests git_commit= ARCH=riscv32-npc \
  NPC_CONFIG=rv32-baseline NPC_ICACHE_WAY_COUNT=2 NPC_ICACHE_REPLACEMENT_POLICY=3 \
  NPC_RUN_TARGET=sim-difftest \
  REF=/home/yong/ysyx/ysyx-workbench/nemu/build/riscv32-nemu-interpreter-so \
  CAPSTONE_HOME=/home/yong/ysyx/ysyx-workbench/nemu/tools/capstone/repo run
```

`test-icache-replacement`要求新输出目录；重复运行时设置
`ICACHE_REPLACEMENT_TEST_OUTPUT=<新目录>`。其他测试日志、边界配置命令、SCC命令和源码哈希
均在`correctness/`及索引中。实际使用的STA工具是仓库流程中的iEDA/iSTA，不能写成OpenSTA。

本轮没有提交、推送或合并远程分支。原有依赖修改与用户任务文件保留。
实验数据、trace和构建目录不应批量加入Git；后续提交只选择源码、脚本、说明和必要的小型结果。
