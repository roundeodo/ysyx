# LSU 与 D-cache：开源实现比较与升级依据

2026-10-01。本轮完成指定版本的文档和关键源码路径评审；没有编译、仿真或综合这些外部项目，
也没有修改本核功能 RTL。下述升级项均为候选，不能写成已经实现或已经测得收益。

目标是改善一般访存行为下的面积与执行时间，覆盖边缘软件的数据准备和控制路径。
不以复现 CVA6 为目标，也不只为 `dinic/lzip/ssort` 调参。此前“两项 load 上下文、再加
hit-under-miss”保留为简单对照；最终结构还必须统一处理 store、恢复、重试和互连。

当前电路以[后端说明](../microarchitecture/BACKEND_DESIGN.md)与
[数据访存说明](../microarchitecture/DCACHE_DESIGN_RECORD.md)为准；已有证据以
[LSU 阻塞实测](../verification/RV32_LSU_STALLS_2026-10-01.md)为准，不在这里复制数值。

## 参考范围与版本

| 项目 | 固定版本/提交前缀 | 本轮研究用途 |
| --- | --- | --- |
| CVA6 | v5.3.0 / `2ef1c1b1fca4` | 顺序发射、多 load 身份、store 提交分离 |
| CV-HPDcache | `a23eac20778c` | 非阻塞查询、挂起与重试、MSHR、缓存行预留 |
| Rocket Chip | `ece7b9ad544b` | 可选非阻塞 D-cache、同一行后续请求、资源冲突与重放 |
| BOOM | `58ef2720eae1`，只核对 `v4/lsu` | 年龄/字节相关检查、转发、投机与恢复代价 |
| CV32E40P | `6033d2b1be32` | 小核两笔 OBI 在途事务、流水线反压和接口前提 |
| Ibex | `4dd3932a36b5`，普通 RV32 路径 | 简单 LSU 的完成、总线错误和排空边界 |

完整提交、文件 SHA-256、永久源码链接与阅读位置见
[来源清单](data/lsu-dcache-review-20261001.json)。HPDcache 的独立提交是另一研究对象，
不宣称它就是 CVA6 v5.3.0 锁定的子模块版本。BOOM 在线手册用于概念说明，具体判断以固定
提交的 v4 源码为准；不把旧手册中的队列字段或检测时机当成当前 v4 实现。

## 从源码获得的设计依据

### CVA6：分开请求接收、结果返回与 store 提交

`load_unit` 保存每条 load 的返回身份；`data_rid` 选择返回项。flush 标记旧项无效，
但尚未返回的事务不能立即复用身份。`store_buffer` 分开未提交和已提交队列，前者可撤销，
后者继续排空。详见已有[CVA6 记录](CVA6_LSU_REVIEW.md)。

值得借鉴的是状态生命周期和请求/完成解耦。两项 load buffer 不是两项 MSHR；MMU 相关
阶段、地址局部比较以及提交后写入的错误契约，都不能直接移植到本核。
[load 源码][cva6-load]、[store 源码][cva6-store]。

### HPDcache：受阻请求离开查询流水线

MSHR 记录正在处理的缺失缓存行；RTAB 保存暂时无法执行的请求，并在条件消除后重试。
同行请求保持顺序，不同行可以分别推进。回填、重试和新查询争用端口；满表、维护和
非缓存操作仍会阻塞。被预留的替换位置不能再次分配。[架构文档][hpd-arch]、[RTAB 源码][hpd-rtab]。

借鉴重点是“为什么等待、何时重试、哪个位置已被占用”，不是复制其三级流水。
本核可先把等待原因与重试选择放进小型 load 表，避免在 LSU 和 cache 各保存一份完整请求。
其多请求方、原子操作、动态写策略及整套控制逻辑不是当前所需。该版本仍有 miss 发起和
store→load 端口冲突等待；这些周期不能仅因成熟项目采用就默认适合本核。

### Rocket：区分缓存行事务与等待该行的操作

`HellaCacheFactory` 按 `nMSHRs` 选择阻塞或非阻塞实现。`NBDcache` 的 MSHR 接收主缺失和
满足条件的同行后续请求，通过 RPQ 保存待重放操作；回填身份按 TileLink source 匹配。
该实现还限制同组并发，不能将 MSHR 数当成任意地址组合的保证。[工厂][rocket-factory]、[MSHR 源码][rocket-nbd]。

可以借鉴同行请求复用一次回填、store 数据与请求描述分开保存、端口仲裁及保留替换位置。
TileLink 一致性、权限升级、probe 和 CPU 收到 nack 后的指令重放不属于本核现有 AXI 契约。
`ready/valid` 接口已经接收的请求必须由唯一所有者保存；不能复制 nack 信号后让请求丢失或重复。
Rocket 的 metadata 等待用于处理真实 RAW 风险；要消除等待，先证明本核阵列旁路足以替代。

### BOOM：转发必须同时满足地址、年龄和字节覆盖

v4 LSU 查找年轻于 store 的 load，记录顺序违例并触发恢复。store→load 转发同时检查
物理地址、字节掩码、数据就绪和年龄；最近的相关 store 不能转发时，不可改从更老的 store
取值。单端口配置还限制重复 load 唤醒，给 store 留出排空机会。[v4 LSU 源码][boom-lsu]。

借鉴转发条件和进展保证，不引入未经测量的大型关联队列、未知 store 地址投机、内存相关
预测器或整套重命名恢复。本核可先等待地址/字节相关得到确认；部分覆盖不能直接当作完整
转发，多项字节合并另作候选。ROB 顺序退休本身不能纠正已经读到错误值的 load。

### CV32E40P：两笔总线在途不等于两条指令完全解耦

LSU 用 `DEPTH=2` 和计数器限制 OBI 在途数；协议要求响应按请求顺序返回。源码同时要求
EX/WB 在有旧事务时按响应交接，因此总线能力不能直接解释成任意两条 load 后都可自由推进。
`PULP_OBI` 的不同取值也改变请求是否依赖旧响应。[LSU 源码][cv32-lsu]、[同提交手册][cv32-doc]。

可借鉴小型计数、反压保持和同拍交接。不能复制其错误前提：这个接口未实现 OBI `err`，
RTL 中 `data_err_i` 标注未使用且断言其为零。我们的 access fault、clean 失败停止及
脏行恢复必须保留，不能以“参考项目更简单”为由去掉。

### Ibex：请求接收不等于操作成功

普通 RV32 LSU 的 load/store 需要等待响应，包括 store 的错误确认。跨字访问有独立的
事务推进和错误排空处理。[同提交手册][ibex-doc]、[LSU 源码][ibex-lsu]。

这是完成语义与简单控制的参考，不是非阻塞 D-cache 样板。借鉴逐请求处理成功/错误/排空，
不采用其阻塞方式替代我们已经存在的独立 FU 重叠，也不扩大本核当前不支持的非对齐访问承诺。

## 需要整体设计的六个边界

| 边界 | 本核候选与电路理由 | 暂不作的承诺 |
| --- | --- | --- |
| 指令与响应身份 | 小型 load 表保存 ROB 身份、地址/操作、已发出/等待/取消状态；返回按身份匹配。未发出的撤销项可释放，已发出的保留到响应排空 | flush 直接清空所有身份、复用槽号后接受旧响应 |
| 接收与调度 | 空表时直通；受阻才保存。只重试已解除原因的项，同一请求只在一个位置拥有发出权 | 加 FIFO 就等于可越过队首受阻 miss；每拍盲目重查所有项 |
| cache 查询与缺失 | 查询端与 miss 状态分开；显式保护被替换行。比较同行等待复用回填与回填后的重查 | 给一项 MSHR 扩数组就自动得到多 miss |
| store 与 load 顺序 | 将 store 地址/数据暂存、允许写入、操作完成、退休分开；先保留退休前错误确认。非相关 load 是否允许越过老 store 单独验证 | store 进入队列即退休；MMIO 投机；未知地址预测 |
| 缓存行数据与错误 | 保留脏 victim 到写回/回填成功，或完成恢复；hit-under-miss 不能读到被覆盖且待恢复的旧行 | 已退休脏数据丢失后只给当前年轻 load 报错 |
| 互连与维护 | AXI 身份/路由与并发度一起设计；FENCE.I 排空新增请求后 clean/invalidate；恢复不能撤销已展示且受阻的请求 | 下层只接一笔却宣称两个 miss 并行；更改计时模型掩盖硬件成本 |

每个队列都要说明保存哪一类尚未完成的责任；不在 Issue、LSU、路由和 cache 重复存整条
uop。load 表是事务状态，不必成为强制经过的一拍；新请求与旧完成同拍时既要考虑容量复用，
也要防止旧错误/数据覆盖新项。仍需 STA 检查组合反馈，不能只依据寄存器数量选型。

store 队列研究并入整体方案，但不急于采用提交后排空。首先可以让未提交 store 的地址/数据
离开 Execute 入口，使年轻独立运算推进；store 仍在 ROB 等待安全执行和完成。若还要让 load
越过它，必须检查所有相关老 store，保留 FENCE/PMA/MMIO 顺序；完全覆盖转发和部分覆盖等待
分别测试。这个选择不要求当前就实现乱序发射队列。

## 实验矩阵：分开结构收益与容量收益

下面是待实现、待测的比较项；不是本轮结果。先统一接口、恢复和错误规则，再逐项实现。

| 项目 | 变化 | 回答的问题 |
| --- | --- | --- |
| A | 当前稳定结构 | 原始参照 |
| B | 只改 D-cache 容量/行长，保持阻塞 | 增加数据容量能解决多少问题 |
| C | 两项/四项 load 状态，原阻塞 cache | 仅接收解耦能否释放独立 FU；深度是否值得 |
| D | C + 单 MSHR hit-under-miss | hit 在 miss 期间可推进的实际收益 |
| E | D + 同行等待/条件重试的简单实现 | 重复请求、同组冲突是否再次阻塞入口 |
| F | E + 两项 MSHR + 所需互连支持 | 外部并发收益是否足够抵消状态、端口与路径成本 |
| S | 在选定 load/cache 基础上单独加入小型 store 暂存，再独立比较转发 | store 顺序与数据依赖的代价，不与 load 优化混算 |

D 必须已具备正确的冲突等待和回填仲裁，E 只比较其进一步减少重复查询/入口阻塞的实现，
不是把必要的正确性状态删掉作对照。同行请求不重复发 refill 是基本要求。

容量初筛覆盖 256 B、512 B、1 KiB、2 KiB；load 项数先比较 2/4，MSHR 先比较 1/2。
这些是初始搜索点，不是预先选定的参数。先单项再组合与消融；固定 ROB/Issue 和软件镜像，
必要时将 ROB 深度另设实验，避免把其容量变化算成 LSU 收益。

## 负载与验收

保留 MicroBench test/train 作为一般软件参照。复用现有 `json_bpe`、`quant_loader`、
`runtime_graph` 三类输出可校验负载，构建入口为[负载脚本](../../scripts/build_selection_workloads.py)。
既有开发 seeds 为 41/73、保留 seeds 为 809/1543；这是已经用过的保留集，不宣称是本轮全新
未见数据。新一轮候选排序用开发集，保留集只做最终检查；若增加独立保留输入，先冻结种子和
参考输出再运行候选。本轮未重新构建或运行这些代理负载。复用时统一 ISA 和工具链，不改
参考算法或结果；原前端脚本构建的 RV32I 镜像不能与 RV32IM 成绩直接混用。

补充定向程序覆盖以下性质，而不依据哪种候选获胜来选测试：

- 连续 hit；同组不同行；同行多个 load；一个 miss 后 hit；两个独立 miss；指针追踪依赖链。
- 连续 store、load/store 交替；完全覆盖和部分覆盖；最近老 store 未就绪；store 与回填争端口。
- 顺序流、跨行访问和不同工作集；区分容量、局部性、带宽与真正可重叠的独立请求。
- 错误路径 load 与旧响应；响应/flush/分配同拍；槽号复用；多响应争完成口；随机反压。
- 较老异常与年轻 store/MMIO；FENCE/FENCE.I、中断排空、读错、写错和脏 victim 恢复。
- 持续新请求或重试时，回填、老请求与 store 仍可推进；不因挂起表满造成死锁。

计数同时记录每类请求被接受/完成、队列占用、阻塞原因、有效重试/无效重查、同行合并、
阵列端口冲突和总线字节数。等待周期可以重叠，不能直接求和当成可节省周期。
既比较同频周期，也比较各自通过 STA 的频点执行时间和面积；沿用用户选择的面积×执行时间
与单项退化检查，不把没有 PPA 的方案称为最优。并发实验还要核对设备时钟延迟、队列和目标
接受能力，避免用无限带宽存储器给新机制制造收益。

## 当前取舍

- 首选设计参考是 CVA6 的身份/提交边界与 HPDcache 的挂起/重试组织；Rocket 补充同行请求
  和资源冲突处理。它们共同决定接口与状态，不以某个项目的模块数量或流水级数为模板。
- BOOM 用于检查年龄、字节转发和恢复是否完整；当前不选择未知地址投机或大型关联 LSQ。
- CV32E40P/Ibex 用于约束面积、握手与错误复杂度，不据其简单外设接口推断 cache 并发能力。
- 不直接集成整个 HPDcache，也不预设只做此前两步。完整 IP、简化自研方案和容量扩展的
  面积/时间目前未在本核做等条件比较，不能宣称谁必然更好。

[cva6-load]: https://github.com/openhwgroup/cva6/blob/2ef1c1b1fca419354920c5487293bc605294904e/core/load_unit.sv#L153
[cva6-store]: https://github.com/openhwgroup/cva6/blob/2ef1c1b1fca419354920c5487293bc605294904e/core/store_buffer.sv#L64
[hpd-arch]: https://github.com/openhwgroup/cv-hpdcache/blob/a23eac20778cb9d1a7269abbbb72f180db5ed32f/docs/source/architecture.rst
[hpd-rtab]: https://github.com/openhwgroup/cv-hpdcache/blob/a23eac20778cb9d1a7269abbbb72f180db5ed32f/rtl/src/hpdcache_rtab.sv
[rocket-factory]: https://github.com/chipsalliance/rocket-chip/blob/ece7b9ad544b07df39cd13b6fd7236562a26355d/src/main/scala/rocket/HellaCache.scala#L261
[rocket-nbd]: https://github.com/chipsalliance/rocket-chip/blob/ece7b9ad544b07df39cd13b6fd7236562a26355d/src/main/scala/rocket/NBDcache.scala#L150
[boom-lsu]: https://github.com/riscv-boom/riscv-boom/blob/58ef2720eae13be26b3008c02b5a74ce29c61c44/src/main/scala/v4/lsu/lsu.scala#L1326
[cv32-lsu]: https://github.com/openhwgroup/cv32e40p/blob/6033d2b1be3295ec774d17ac4cf226faacfdeb08/rtl/cv32e40p_load_store_unit.sv#L351
[cv32-doc]: https://github.com/openhwgroup/cv32e40p/blob/6033d2b1be3295ec774d17ac4cf226faacfdeb08/docs/source/load_store_unit.rst
[ibex-doc]: https://github.com/lowRISC/ibex/blob/4dd3932a36b5af5ac002bddbe16a1b4ead1a6fd8/doc/03_reference/load_store_unit.rst
[ibex-lsu]: https://github.com/lowRISC/ibex/blob/4dd3932a36b5af5ac002bddbe16a1b4ead1a6fd8/rtl/ibex_load_store_unit.sv
