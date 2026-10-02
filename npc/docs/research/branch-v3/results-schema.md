# 结果与证据字段

## 测量层次

- M0：正确路径、逐分支立即训练。错误数、学习曲线、逻辑状态bit；没有CPU时间。
- M1：按实际query/accept/resolve事件重放。事件差用于机会诊断，不能重建候选改变后的错误路径或估算净加速。
- M2：候选RTL实际驱动PC、I-cache、队列、执行与恢复。同镜像、同物理ns服务重新运行，只有这层进入硬件性能比较。
- native：完整ysyxSoC、device-clock-v1、100MHz设备。MicroBench原生计时窗口；与独立M2分开。

## 文件

| 文件 | 内容 |
| --- | --- |
| baseline_manifest.json | 开始时HEAD fbe7824及未提交差异的文件哈希；这些修改随后冻结为c2cf8c3 |
| measurements.json | 每次完整RTL运行的配置、窗口周期/退休/IPC、秒数、互斥停顿分类、总线beat、查询次数、log与可用的binary哈希 |
| retired-equivalence.json | 配对退休PC/instruction/next-PC序列的计数与SHA256；不要求cycle或query ID相同 |
| m0-results-v2.json、geometry-screen.json、local-screen.json | 算法模型结果；老m0状态bit字段未包含后来加入的折叠寄存器，成本比较优先用geometry-screen与实际综合 |
| author-warmup.json | 作者原版参考，ROI冷启动/自然前缀，学习曲线与原始输入哈希 |
| attribution.json | 当前十四个开发窗口、六种配置逐控制流对齐；方向、BTB目标缺失、早期/EX纠错、周期占用及宿主耗时分开统计 |
| corrector-attribution.json | TAGE四消融的真实查询快照与选择状态核对；SC/Loop分别改对和改错、provider类别与阈值分布 |
| disagreements.json | 按真实控制流顺序配对的帮助/伤害；明确早期事件是否记录，未记录不填0冒充无事件 |
| timing-opportunities.json | 分级BTB的固定事件重放、操作数就绪间隔、目标编码覆盖；没有候选CPU时间 |
| coverage.json | 每项机制的来源、模型、RTL、验证、PPA和缺项 |
| selection-freeze.json | 最终保留执行前冻结的候选、二进制、频率、预算、权重与默认门槛 |
| evidence-index.json | 原始日志、输入、源码快照、综合命令和STA报告的索引/哈希 |

独立RTL窗口为(begin退休,end退休]，两条原有测量NOP界定；校验在窗口外的真实软件使用独立输出数组。单位是CPU周期；seconds=cycles/(MHz×10^6)。存储首响应100ns、beat10ns，具体用该次频率换算，不是把旧周期数除以新频率。

`same_frequency`只配对同镜像路径、同latency/random_stalls/seed和同MHz；`versus_baseline_720MHz`使用720MHz B0。同一组合的重复运行只检查一致性，不当作独立样本。家族内输入等权、家族间等权，既报告逐项又报告几何平均及最差值。

主应用比较由原代理家族与jsmn/miniz自然请求流组成；同一软件冷/暖窗口在家族内等权。独立config重复三次的real-images-v2是另一组报告，不再重复加权。机制程序、oracle及MicroBench不加入目标应用总分。

## 被动事件

Q=接受预测查询，A=fetch entry交付，E=局部early redirect，F=全程序控制流解析，R=窗口内控制流解析及预测结果，C=全程序退休，O=译码分支操作数/反压状态，S=外部恢复。64bit dynamic_id串联事件；短frontend_tag只作运输标签。早期源快照没有F/O或E时，对应分析明确缺失。

M/P是验证开关下的边沿前输入/上下文及边沿后全逻辑状态；不参与正常综合。provider、epoch、历史、tag/index、SC和loop上下文按具体几何解码。无效表项payload不定义，比较时屏蔽；有效counter、tag、useful、fold和选择状态逐项检查。

## 证据保留

完成的次要trace允许gzip无损压缩：先校验解压SHA256相同，再移除原未压缩文件；trace-compression.json保留原始SHA256。已链接构建只清.o/.a/.gch，保留可执行文件、源码、配置和日志；object-pruning.json核对清理前后可执行文件SHA256。失败日志和原始错误轨迹不删除。

早期run index未记录可执行文件哈希时，标为缺项，不能事后用当前binary哈希伪装当时记录。该次build manifest和源码快照仍保留。PPA是同一Nangate45标准单元库、AREA 3、映射820MHz的全核结果，合法频点必须setup/hold/gating四组全部通过；不是布局布线签核，也不是功耗测量。
