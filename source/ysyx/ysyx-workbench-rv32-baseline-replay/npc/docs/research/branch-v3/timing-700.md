# TAGE＋SC＋Loop 的 700 MHz 检查

当前缩放版TAGE＋SC＋Loop整核已通过700 MHz。旧NSL的540 MHz是初版实现结果，不是该组织的上限。最终保留集尚未运行，完整选型尚未冻结。

旧NSL冻结网表在700 MHz、原SDC下的主要违例：

| 路径 | 到达时间 | slack |
| --- | ---: | ---: |
| EX寄存器→有效地址→LSU直通→uncached AXI控制输出 | 1.455 ns | −0.313 ns |
| 预测响应→下次查询→TAGE/SC→预测响应 | 1.651 ns | −0.262 ns |
| 前端预测PC的时钟门控使能 | 1.597 ns | −0.218 ns |

证据：`result/branch-v3/ppa/NSL/sta/riscv32_core_reset_boundary-700MHz-buffered/`。IO延迟仍为周期的20%，没有放宽约束；540 MHz是整核结果，不是SC独立模块的频率上限。

第一项电路试验：SC对两个可能的TAGE方向并行查询和求和，将方向选择移到末端；总和缩为有数学范围依据的8bit。算法、预测/训练时机、接口及寄存器边界不变。先以独立软件模型逐查询/逐状态验证，再用同一AREA 3流程测整核。该试验只改预测器，不把其他路径的映射变化直接解释为预测算法收益。

共享电路改动提供稳定基线对照；无需新增流水级就已达到700 MHz。

第二项独立增量试验：在SC并行版上，把tagged counter读出提前到tag比较的并行支路，用最长/次长匹配的独热向量选方向和弱项。旧700 MHz报告中可见provider选择之后又经过较长counter选择链；该改动消除编码表号对读数的串联依赖。无新增寄存器，先后版本分别冻结源与PPA，不能把两次改动的效果混报。

## 已测结果

同一NanGate45、AREA 3、820 MHz映射目标、原IO/复位约束；各频点复用各自冻结网表。结果是综合后STA，不含布局布线寄生。

| 版本 | 整核面积 μm² | 20 MHz网格通过点 | 700 MHz最差setup slack |
| --- | ---: | ---: | ---: |
| NSL，原串联查询 | 119382.928 | 540 MHz | −0.313 ns |
| NSL-parallel，仅SC并行 | 119623.126 | 660 MHz | −0.068 ns |
| NSL-provider，再并行tag/counter选择 | 119774.214 | 660 MHz | −0.042 ns |
| NSL-victim，再缩短I-cache victim选择 | 119986.748 | 700 MHz | +0.027 ns |

最后一版在700 MHz的data setup、gating setup、data hold、gating hold最差slack分别为+0.027、+0.043、+0.059、+0.097 ns，报告无违例。720 MHz的setup slack为−0.006 ns，不列为通过点。最终面积比原NSL增加603.820 μm²（0.506%）；状态位数、预测周期和寄存边界不变。

5 MHz细扫进一步通过715 MHz。相同I-cache改写下，B0-victim面积101348.394 μm²，720 MHz通过，细扫通过735 MHz；原B0off面积101424.470 μm²、最高已验证720 MHz。因此该共享改写未损害基线。700 MHz NSL工作点比对应B0多18.39%面积，不能把相对旧NSL的0.506%增量误当成相对BHT基线的成本。

SC并行版增加240.198 μm²（0.20%）。其700 MHz瓶颈是数据AXI响应→后端完成/反压→I-cache hit前递→替换结果寄存器；不是SC求和。预测器变化也会改变展平整核的技术映射，不能把其他逻辑路径的改善都归因于SC本身。

两次电路改写分别通过四消融36,000事件、八种几何96,000事件、推测恢复36,000事件、定向9,196事件；真实整核两输入各323,672次查询/更新后状态对照通过。十个开发代理输入的RESULT、COUNTERS、DETAIL完全一致。第二版另通过原有fetch/FENCE.I/dirty恢复/精确异常四组安全检查与十项NEMU DiffTest。有限步形式检查范围仍仅为混合选择组合逻辑和小几何失效优先级，不能说成整核形式证明。

实验目录均在`result/branch-v3/`：`ppa/NSL*`、`geometry-{sc,provider}-parallel`、`spec-{sc,provider}-parallel`、`directed-{sc,provider}-parallel`、`formal-{sc,provider}-parallel`、`rtl/NSL-{parallel,provider}-{dev,state}`，以及`isa/difftest/NSL-provider`和`safety/NSL-provider`。逐周期对照摘要为`sc-parallel-cycle-equivalence.json`和`provider-parallel-cycle-equivalence.json`。

复测指定频点：`python3 npc/tools/branch_v3/probe_ppa.py NSL-parallel --mhz 700`。脚本检查输入网表/SDC哈希，不重映射，不改变约束；已有完整结果只读取。

第二版700 MHz测得data slack −0.042 ns，gating slack +0.011 ns，仍卡在同一I-cache victim前递路径。第三项试验因此直接修改该组合选择：两/四路13～16策略并行确定最大RRPV，以路号打破平局，删除反复编码victim后再索引RRPV的依赖；保留同拍hit前递、原寄存边界和所有策略更新。此项属于共享I-cache电路优化，必须同时重测B0控制，不能算成TAGE-SC-L算法收益。

第三版的替换模块通过2/4/8路、四种策略共12配置297,616次独立C++决策比对。NSL-victim与B0-victim均通过四组整核安全回归和十项NEMU DiffTest；各自10个代理输入及4个真实软件请求流的周期/退休/分支/cache计数与原对应版本完全相同。原始结果见`victim-parallel-unit/manifest.json`、`victim-parallel-cycle-equivalence.json`、`safety/{NSL,B0}-victim`和`isa/difftest/{NSL,B0}-victim`。

这些是电路等价优化，同频预测准确率和周期没有变化。不同主频下存储服务仍以物理ns计时，必须重跑，不能直接按540/700缩放执行时间。SC并行候选会增加组合读出和运算活动；本轮没有可靠功耗测量，不宣称功耗降低。

配置范围：base32、3×16 tagged、8bit tag、3/7/16历史、SC 3×16权重、4项loop，解析时更新历史；BTB16/2路、RAS4，early target/RAS关闭。700 MHz不代表作者完整8KB参考或所有参数组合均已达到该频率。

## 性能与归因

七个应用家族等权的14个开发输入/窗口，NSL-victim@700相对相同I-cache的B0@700，时间几何平均比为0.996863（快0.31%）；相对B0@720为0.999057（快0.09%）。相对原NSL@540实测为0.937994（快6.20%），并不是按频率比推算。这里只比较明确的700/720工作点；715/735的资格不能替代相应软件实测。

0.31%对应早期直接目标和早期RAS均关闭的配置，不能概括为完整TAGE分支预测子系统的收益上限。
负载规模、原始方向错误与实际纠错的区别见[负载与收益归因](attribution.md)。这些短窗口尚不满足最终代表性验收；用户要求不运行train，后续扩展目标软件负载。

原生SoC MicroBench **test**：NSL-victim@700的Total为0.003814 s、IPC 0.311481269；Scored为0.001509 s、IPC 0.406681164。B0-victim@720的Total为0.003854 s、IPC 0.299829936；Scored为0.001512 s、IPC 0.395383988。均通过观察器开关对照，设备100 MHz，软件可见timer为1 MHz；本轮没有重新跑train。计时量化与Scored多个窗口求和保留在原始report，不用一组窗口的IPC解释另一组时间。

完整数据和哈希见[timing-700-results.json](timing-700-results.json)，重建汇总：`python3 npc/tools/branch_v3/collect_timing.py`。这证明700 MHz可行；是否最有性价比仍须与同样优化后的混合、早期目标、RAS和TAGE消融比较，不能仅凭频率推荐默认启用。
