# 前端探索：学习与复跑入口

本次面试发布固定 2026-09-24 的 RV32 设计；参数与构建命令以
[版本说明](../interview/RV32_REMOTE_SNAPSHOT.md)为准。研究面向边缘 AI 软件中的解析、
量化装载和 runtime 控制代理，没有把这些程序称为完整神经网络推理。

## 按问题阅读

| 阶段 | 研究记录 | 应掌握的结论 |
| --- | --- | --- |
| 负载、计时和初筛 | [前端探索](../verification/FRONTEND_EXPLORATION_2026-09-21.md)、[计时规则](../verification/MICROBENCH_TIMING_RULES.md) | 先核对 CPU 周期、计时窗口和内存模型，不能用 toy IPC 代替整核 RTL |
| I-cache 容量与策略 | [选型与对照](../verification/ICACHE_SELECTION_2026-09-21.md)、[阅读笔记](FRONTEND_RESEARCH_NOTES.md) | 扫描容量、路数、行长与多种替换；区分扩容、公共电路、策略和查询旁路的收益 |
| 分支目标与准入 | [初轮](../verification/BRANCH_EXPLORATION_2026-09-22.md)、[补充](../verification/BRANCH_FOLLOWUP_2026-09-23.md)、[目标编码](../verification/BRANCH_TARGET_EXPLORATION_2026-09-23.md) | taken 准入、替换和 BTB-X 启发的目标编码各有预算及跨区间退化 |
| 更强的方向预测 | [历史/TAGE 实验](../verification/BRANCH_HISTORY_EXPLORATION_2026-09-24.md)、[比较表](../verification/data/branch-history-20260924/README.md)、[阅读笔记](BRANCH_RESEARCH_NOTES.md) | 方向错误下降不等于相同比例的时间下降；同时检查目标缺失、数据等待、频率与面积 |

论文和作者 artifact 的入口、固定版本、阅读范围、原系统资源及本核实际借鉴均在两份
阅读笔记中。模型、RTL 原型和完整移植分别标注；未实现的 SC、推测历史或大型后备表
不能作为本核能力。失败实验、模型修正和负结果保留，不只展示胜者。

I-cache 最终采用 1 KiB/4 路/32 B 的分段访问 RRIP，借鉴 ACIC 对连续行内访问和
跨段重用的区分，没有实现完整 ACIC。查询旁路利用 miss 分配与新查询互斥的实际协议。
分支预测继续使用 BHT16/BTB16 两路/RAS4；小型 TAGE 在共同 700 MHz 下开发时间改善
约 0.312%，但相对基线面积增加约 6.91%，不足以抵消成本，因此默认关闭。

## 源码入口

- 模型：`npc/tools/icache_explore/model.cpp`、`npc/tools/branch_explore/direction_model.cpp`，
  以及 `npc/scripts/model_*.py`；模型用于筛选，最终执行时间以 RTL 为准。
- 电路：[替换](../microarchitecture/ICACHE_REPLACEMENT_DESIGN.md)、
  [BTB 策略](../microarchitecture/BTB_POLICY_DESIGN.md)、
  [目标编码](../microarchitecture/BTB_TARGET_STORAGE_DESIGN.md)、
  [方向表](../microarchitecture/DIRECTION_PREDICTOR_DESIGN.md)、
  [TAGE](../microarchitecture/TAGE_DESIGN.md)。
- 软件：`npc/tests/frontend_selection/`、`npc/tests/branch_workloads/`；包含 vendored 源码、
  许可证与版本清单。生成器固定开发/保留种子并独立校验输出。
- 整核环境：`npc/tests/frontend_exploration/`，被动计数、物理延迟模型及协议探针。
- 流程：`npc/scripts/explore_*.py`、`test_*.py`、`audit_*.py` 和 `reproduce_*.py`。
  `reproduce_*` 用于历史归档，不会从 Git 自动重建已经排除的旧快照。

## 从源码做新实验

在仓库根目录执行；不需要历史仿真结果：

```sh
python3 -m unittest discover -s npc/scripts -p 'test_history_model.py'
python3 -m unittest discover -s npc/scripts -p 'test_history_timing.py'
export NPC_HOME="$PWD/npc"
make -C npc NPC_CONFIG=rv32-balanced git_commit= test-config lint-npc test-predictor
```

研究入口有些保留旧实验默认参数。新实验必须显式指定配置、频率、物理延迟模式和输出
目录；`NPC_CONFIG=rv32-balanced` 只影响 Makefile，不会自动修改 Python 参数。
软件镜像可由 `build_selection_workloads.py` 和 `build_branch_workloads.py` 重新构建；
`--help` 给出输入/输出参数。完整历史矩阵的命令见对应研究记录。

综合脚本在 `npc/tools/icache_explore/sta_flow/`，工具二进制和库另行安装：

```sh
python3 npc/scripts/prepare_selection_toolflow.py \
  --installed /path/to/ieda-toolflow --output /tmp/rv32-study-flow
export NPC_STA_TOOLFLOW=/tmp/rv32-study-flow
```

该变量供研究 PPA 脚本使用；直接调用 Makefile 时传 `STA_TOOL_DIR=/tmp/rv32-study-flow`。
需要 Yosys/Slang、iEDA 和 NanGate45 库。工具或库版本不同就是新测量环境。

## 本次提交什么

保留可学习、可修改和可重新运行的源码与研究记录，比较数据只保留精简汇总。
原始日志、trace、波形、镜像、网表、编译缓存及压缩快照不上传。
研究文档中的历史路径和哈希保持测量原值；本机原始 result 已于 2026-09-24 清理，不能直接运行依赖完整旧归档的历史证据审计，
也不能宣称已在全新环境完整复现历史矩阵。
