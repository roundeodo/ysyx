# 旧核接入正式混合预测方案

## 当前配置

工作区 `ysyx-workbench-rv32-baseline-replay`，Git 基点 `316d1d2`；此前已恢复旧硬件
`e3b018f` 的工作区差异保持为起点。本次只接入正式选定的预测行为与所需恢复连接。
I-cache 保持 256 B、单路、16 B 行、policy0；D-cache 关闭；RV32I 单发射顺序核，保留前递。
预测为 BHT16、BTB16/两路/完整目标/轮转、RAS4、弱态 BTFNT（static2）、早期 B/J 目标。
TAGE、SC、Loop、推测历史、早期 RAS 和其他 BTB 实验均未接入，不复制正式版缓存或后续优化。

并行表查询与唯一响应级保留；新增两位请求方向快照随现有载荷传递，不增加周期。
I-cache 返回后用正式版原样的 `branch_choice`、`direct_target` 计算方向及直接目标。
IFU 采用正式版早期恢复协议：当前指令正常交付，更新其预测信息，清年轻预测并递增 epoch；
已展示且受阻的缓存请求保持，旧 epoch 响应排空，外部恢复优先。
EX 结果增加真实 `branch_taken`，训练及监视不再以 next-PC 是否等于 PC+4 推断方向。

默认 Makefile 和性能脚本启用上述组合。`--predictor-enable 0` 同时关闭预测表和早期目标。
旧纯动态对照使用 `--predictor-enable 1 --branch-static 0 --early-target 0`。
性能脚本拒绝本 replay 没有实现的实验参数，避免参数记录与实际电路不符。
实现说明见 [预测器电路](../microarchitecture/FETCH_PREDICTOR_DESIGN_RECORD.md)。

## 验证

- 独立模型：混合及旧纯动态分别覆盖 5 组容量/路数，每组配置共 60000 周期；随机训练、
  查询、响应反压、flush、invalidate、复位及 RAS 溢出/下溢均通过。
- B/J 译码与强弱方向：125 组检查；额外验证 taken 与 not-taken 都可指向 PC+4。
- IFU 早期目标：6 个随机种子各 12000 周期，覆盖受阻请求、外部恢复与响应同拍、维护暂停。
- 无预测模式：12000 周期，7726 请求、1487 拍反压、169 次 flush，元数据始终零。
- FENCE.I、非分支错误 taken、clean 错误停止和 dirty-victim 恢复：84 个整核场景通过。
  为覆盖原有写回错误，这组测试显式临时开启 D-cache；train 配置仍关闭 D-cache。
  首次编译遇到既有故障注入测试引用错误的 generate 层级；修正观察路径并保留方向快照后
  完整重跑，未删除场景或关闭断言，首次失败日志保留。
- 当前配置 lint 无错误；MicroBench test 十项全部通过，观察器开/关输出、计数和架构校验一致。

| test 原生窗口 | CPU 周期 | 退休指令 | IPC | timer 时间 |
| --- | ---: | ---: | ---: | ---: |
| Total | 5698637 | 822246 | 0.144288187 | 8.141 ms |
| Scored | 3102444 | 430311 | 0.138700650 | 4.432 ms |

接入时未运行 train 或新的 NEMU DiffTest。随后用户完成的 train 及本轮容量对照见
[容量与瓶颈记录](RV32_REPLAY_ICACHE_CAPACITY_2026-10-11.md)。尚未重新综合/STA，因此先前的 36505.840（无预测）和
47692.204 µm²（旧预测）均不能当作本次新组合的面积。700 MHz 是对齐实验的仿真参数，
本记录没有新增硬件时序资格声明。旧纯动态对照保留本次显式 taken 修正，不称为逐字原始硬件。

## 启动 train

在本 worktree 重新构建，不能 resume 旧的无预测或旧预测模拟器：

```bash
cd /home/yong/ysyx/ysyx-workbench-rv32-baseline-replay
python3 npc/scripts/run_microbench_perf.py \
  --scale train --cpu-mhz 700 --timing-model device-clock \
  --predictor-enable 1 --dcache-enable 0 \
  --icache-bytes 256 --icache-ways 1 --icache-line 16 --icache-policy 0 \
  --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 \
  --direction-policy 0 --ras-entries 4 --branch-static 2 --early-target 1 \
  --output npc/result/performance/replay-hybrid-train
```

CPU 参数 700 MHz、设备 100 MHz、`device-clock-v1`；原生计时器报告物理模型时间，
Total/Scored IPC 分别统计相同计时窗口的退休数和 CPU 周期。
输出目录采用受管理的覆盖策略，完成后保留 `report.json`、配置和小型日志，清理大编译产物。
该配置的结果反映旧核加正式预测，不能与正式版缓存组织的总收益混为一项。

## 证据

`data/replay-hybrid-20261011/before.tar.gz` 及 staged/unstaged 差异保存接入前的工作状态。
`summary.json` 保存当前配置、源码哈希及未运行项；`units/`、`safety/` 保存模型与安全回归
命令、来源哈希及压缩原日志；`manifest.json`、`report.json` 是本次 test 原生窗口证据。
`after.tar.gz` 保存本次完整 RTL 及新测试/脚本，`hybrid.patch` 记录已有文件差异；
接入前快照保留原工作状态。大编译目录已清理。

重复验证：`python3 npc/scripts/test_replay_predictor.py`。本次没有修改 interview 工作区，
没有提交或推送。
