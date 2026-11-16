# 等待优化证据与复现

结论见 [优化记录](../../RV32_WAIT_OPT_2026-10-02.md)。`comparison.json`汇总所有候选，
`baseline.json`绑定提交、原工作区差异和配置，`preexisting.patch`保护任务开始前的NPC修改。
`selected/implementation.patch`是最终RTL改动；默认700 MHz。以包含本目录的Git提交为发布版本。

## 原始结果索引

| 目录 | 内容 |
| --- | --- |
| `baseline` | 本轮重新测量的基线软件、PPA |
| `dirty-dispatch` | 单独写回/回填同拍旁路；未进入最终默认 |
| `frontend-restart` | EX及早期目标恢复同拍查询原型；含最初观测器失败日志 |
| `frontend-ex-restart` | 仅EX恢复查询原型 |
| `cache-handoff` | miss完成当拍接新lookup及16个定向测试的补丁 |
| `array-forward` | 最终硬件的单项700 MHz性能和PPA |
| `combined` | 阵列转发＋写回旁路的失败组合及其完整安全回归 |
| `selected` | 最终RTL/测试补丁、源码身份核对、回归及NEMU DiffTest |
| `final-715` | 最终硬件715 MHz原生性能、软件窗口和随机反压结果 |
| `baseline-observer-check` | 新观测器重测基线，14个窗口结果和计数不变 |

`native/report.json`记录原生定时器窗口、周期、退休数和IPC，`manifest.json`绑定构建参数及镜像，
`simulation.txt`是原始输出。`proxy/{dev,streams}/results.json`保留每个输入的编译/运行命令、
校验值、周期与总线计数；715 MHz目录还包含两组random结果。
`ppa/configuration.json`记录RTL哈希与综合命令，`timing.json`记录频点与四类约束，
`*.rpt.gz`是原始STA报告的无损压缩。`evidence-index.json`记录文件路径与哈希。
`checks`保存make命令、原始输出及错误注入清单；`difftest`包含参考库与软件镜像哈希。

阶段结束后清理的只有本任务标记目录中的编译对象、仿真器、临时RTL副本及网表。
报告中的旧可执行文件路径因此不一定存在；用保存的源码补丁和命令重建。
原型补丁相对`e751542b`生成，应在隔离副本应用，不能覆盖用户当前工作区。
观测器修改适用于所有原型；`selected/test.patch`还含任务开始前已有的流水控制测试改动，
二者可通过`preexisting.patch`区分。未将实验原型加入正式filelist。

## 重跑当前配置

以下从仓库根目录执行，使用固定可覆盖工作目录。`proxy.py`的实验名称要使用新名称，
防止覆盖已归档证据；不同构建不要同时使用同一个工作目录。

```bash
make -C npc git_commit= NPC_CONFIG=rv32-balanced test-dcache test-dcache-recovery test-fence-i test-precise-exception test-pipeline test-fetch
python3 npc/tools/wait_opt/difftest.py
python3 npc/tools/wait_opt/proxy.py replay700 --random-checks
python3 npc/tools/wait_opt/proxy.py replay715 --mhz 715 --random-checks
```

软件窗口复用`result/branch-v3/images`及`streams-development`中的冻结输入。若已清理，可用
`scripts/build_branch_workloads.py --dev-seeds 2411 2418`及`tools/branch_v3/build_streams.py --split development`
在对应目录重建；必须核对原结果中的镜像哈希及校验值后再作比较。不是重新挑选测试集。

```bash
python3 npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 \
  --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 \
  --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 \
  --direction-policy 0 --ras-entries 4 --branch-static 2 --early-target 1 \
  --output npc/result/wait-opt-perf/current
```

715 MHz实测只将`--cpu-mhz`改为715，不手工换算原周期数。最终默认仍700 MHz。

```bash
python3 npc/scripts/run_synthesis.py --target sta-reset --keep-artifacts \
  --output npc/result/wait-opt-synthesis/current NPC_CONFIG=rv32-balanced \
  STA_FREQUENCY_MHZ=820 'STA_SYNTH_STRATEGY=AREA 3' \
  STA_TOOL_DIR="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow"
python3 npc/tools/wait_opt/timing.py replay
python3 npc/tools/wait_opt/compare.py
```

这里显式沿用已有的可工作toolflow；仓库旁的另一个旧Yosys入口不能直接处理当前SystemVerilog，
最初失败输出保留在run-history中。没有更换综合策略取得“优化收益”。频率扫描检查数据及门控
四类时序；较低频点可能是保守跳点，不把单个合法点冒充精确最高频率。
