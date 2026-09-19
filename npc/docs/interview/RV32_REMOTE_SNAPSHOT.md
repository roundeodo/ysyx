# RV32 远程版本：2026-09-11

分支：`rv32-interview-20260911`，仓库：`https://github.com/roundeodo/ysyx`。
此版本保存 RV32 顺序核、定时中断、时序和流水线优化、低侵入性能统计及相关文档。

## 获取和恢复依赖

```sh
git clone --branch rv32-interview-20260911 https://github.com/roundeodo/ysyx.git
cd ysyx
python3 npc/scripts/restore_rv32_dependencies.py
```

父仓库固定四个外部仓库的基线提交。MicroBench 和 ysyxSoC 的本地改动完整保存在
`npc/dependencies/rv32/`，恢复脚本初始化依赖后应用补丁，并安装本版本的生成 SoC。
不向上游仓库写入提交。执行后这两个依赖显示为 modified 是预期状态；不要直接 reset。
可运行 `python3 npc/scripts/restore_rv32_dependencies.py --check` 核对依赖。

系统仍需要原项目的 RISC-V GNU 工具链、Verilator、C++ 编译器及 Capstone。
构建或运行 make 时传 `git_commit=`，关闭课程旧脚本的自动提交行为。

## 2026-09-15 更新

移除独立 RR 流水级，并将取指预测器拆分为 BHT、BTB、RAS 与查询控制模块。
回归测试及同频 MicroBench test 对照通过；拆分前后周期数与 IPC 一致。
该阶段综合单元面积 76,480.320 μm²，730 MHz 下 setup slack 为 +0.023 ns。
此版本尚未重跑 train，下方 train 数据属于 9 月 11 日发布的旧版硬件。
详细条件见 `../verification/RV32_PREDICTOR_SPLIT_2026-09-15.md`。
预测器对照测试引用远程历史提交 `f7a8f2568ea98c9a3492f60bedd7340f936baca4`，
其原始预测器源码 SHA-256 与开发分支冻结版本相同。

## 2026-09-19 更新

前端采用单级预测查询；其余 RTL 按电路结构整理，目录按流水线功能分层，模块名缩短。
旧 decode/RR 寄存级、组合重定向仲裁和未接入的 AXI 错误目标移入 `experiments/`，
不再进入当前编译清单。源码、编码规范、当前模块说明与测试入口同步更新。

该阶段综合后测量：面积 73,037.748 μm²，估算 Fmax 712.892 MHz；700 MHz 的
setup、hold 与门控检查通过。MicroBench **test** 的 Total 定时器时间为 0.006426 s，
同窗口 IPC 为 0.169737606；本版尚未重跑 train。测量口径及源码快照见
[复测记录](../verification/RV32_READABILITY_PPA_2026-09-19.md)。之后的命名与历史模块迁移
通过内容核对及编译/流水控制检查，迁移前后展开的 CPU RTLIL 完全相同。

## 2026-09-20 更新

补入精确异常年龄约束修复及两轮直通优化。最终核及复位电路的综合面积为
69,536.922 μm²，600 MHz 的 data setup 余量 +0.034 ns，setup/hold 与门控检查通过。
MicroBench **test** 的 Total 定时器时间为 0.005923 s，同窗口 IPC 为 0.215102228；
精确异常 40/40、DiffTest 35/35、定时中断 8/8 通过。当前版 train 尚待复测。
逐模块取舍和测量口径见[等待周期复查](../verification/RV32_WAIT_AUDIT_2026-09-19.md)。

## 历史版本已验证的性能

RV32 baseline，CPU 820 MHz，设备 100 MHz，MicroBench train 十项 PASS、GOOD TRAP：

| 窗口 | 原生定时器时间 | 同窗口 IPC |
| --- | ---: | ---: |
| Total：含准备、验证和循环内输出 | 1.911282 秒 | 0.170242182 |
| Scored：十项计分窗口之和 | 1.278899 秒 | 0.178135953 |

原始日志、采样和报告保存在 `npc/result/performance/passive-train-ready-20260906/`。
该目录名称沿用准备阶段名称，train 现已完成。test 做过观察器开关对照，train 仅运行一次。
历史插桩成绩、当前低侵入成绩和官方参考不能直接混作同一个比较口径。

复测使用源码构建，生成新的结果目录：

```sh
python3 npc/scripts/run_microbench_perf.py --scale train --cpu-mhz 600
```

远程保存 RTL、脚本、测试、文档、依赖补丁和精选测量证据；宿主仿真器、编译缓存及
大体积中间网表仍留在原工作机。因宿主仿真器未上传，不对远程克隆的历史归档使用
`--resume`，应使用上面的源码构建入口。归档 manifest 中的绝对路径与哈希保留测量时原值。
面积和时序沿用已有综合记录，本次发布没有重新综合，也没有重新运行长时间 train。
