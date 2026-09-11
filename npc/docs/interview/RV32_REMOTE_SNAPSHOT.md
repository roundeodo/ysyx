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

## 已验证的性能

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
python3 npc/scripts/run_microbench_perf.py --scale train --cpu-mhz 820
```

远程保存 RTL、脚本、测试、文档、依赖补丁和精选测量证据；宿主仿真器、编译缓存及
大体积中间网表仍留在原工作机。因宿主仿真器未上传，不对远程克隆的历史归档使用
`--resume`，应使用上面的源码构建入口。归档 manifest 中的绝对路径与哈希保留测量时原值。
面积和时序沿用已有综合记录，本次发布没有重新综合，也没有重新运行长时间 train。
