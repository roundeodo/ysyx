# RV32 面试版本

更新日期：2026-09-24。仓库 `roundeodo/ysyx`，分支 `rv32-interview-20260911`。
后续面试以本分支的 `NPC_CONFIG=rv32-balanced` 为准；旧 `rv32-baseline` 保留作实验对照。

## 固定的设计

这是 RV32I 单发射顺序核，支持 Zicsr、Zifencei、基础 M-mode 异常、定时中断和 mret。
没有独立 RR 流水级。当前没有乱序、多发射、MMU、硬件乘除法或 AI 加速器。

| 项目 | 面试配置 |
| --- | --- |
| I-cache | 1 KiB，4 路，32 B/行，8 组；策略 13：分段访问 RRIP，查询只前递同组命中更新 |
| D-cache | 256 B，2 路，16 B/行，8 组；阻塞式 Write-Back / Write-Allocate |
| 预测器 | BHT 16 项二位计数器；BTB 共 16 项、2 路、完整目标；RAS 4 项 |
| 实验开关 | gshare、小型 TAGE、压缩目标和 BTB 新策略保留源码，稳定预设关闭 |
| 当前 PPA | 含复位边界的整核 mapped cell area 101,418.618 μm²；综合后完整 STA 通过 720 MHz |

PPA 对应最新研究中的 B0I：新代码关闭预测实验，与冻结 B0 的周期、功能和计数一致。
使用 NanGate45、Yosys/Slang AREA3、820 MHz 映射目标和 iEDA STA；720 MHz 是
20 MHz 网格上通过 data/clock-gating setup、hold 检查的运行点，不是布线后硅上保证。
本次发布只固定已有设计和验证记录，没有重新综合或运行长时间 train。
发布核对通过：67 个 CPU RTL 文件与已测研究源码逐字一致；固定配置展开、整核 lint、
预测器 10 配置共 120000 周期协议测试、38 项模型/统计测试及 335 项 STA 搜索边界检查。
第三方源码与许可证按原始字节保留，发布没有改写 vendor 文件。
本次又以固定配置通过定时中断 8 项回归：3 种延迟的汇编系统测试、2 项 AM 系统测试、
CLINT／中断控制／IFU 恢复 3 项模块测试。命令为
`make -C npc NPC_CONFIG=rv32-balanced git_commit= test-timer-interrupt`。
旧 interrupt 工作树已移除，独有原型仅存本地分支提交 `05608a1`，面试核不依赖该目录。

保留已有精确异常、非分支错误 taken 纠正、FENCE.I 维护、clean 失败停止和 dirty-victim
恢复。结构及选择理由见[架构说明](RV32_ARCHITECTURE_ATLAS.md)、[设计取舍](RV32_DESIGN_CHOICES.md)。

## 获取和构建

```sh
git clone --branch rv32-interview-20260911 https://github.com/roundeodo/ysyx.git
cd ysyx
export NPC_HOME="$PWD/npc"
python3 npc/scripts/restore_rv32_dependencies.py
python3 npc/scripts/restore_rv32_dependencies.py --check
make -C npc NPC_CONFIG=rv32-balanced git_commit= test-config lint-npc
```

依赖的固定提交、补丁和必要的 SoC 集成 Verilog 保存在 `npc/dependencies/rv32/`。
恢复脚本初始化子模块、应用补丁并安装集成源文件；不写入上游提交。恢复后两个依赖
显示 modified 属正常现象。仍需安装 RISC-V GNU 工具链、Verilator、C++ 编译器及 Capstone；
`git_commit=` 关闭课程 Makefile 的自动提交行为。

性能脚本为保留历史调用，仍有旧配置默认值；测试本面试版本必须显式指定：

```sh
python3 npc/scripts/run_microbench_perf.py --scale train --cpu-mhz 720 \
  --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 \
  --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-target-bits 0 \
  --btb-policy 0 --direction-policy 0 --history-bits 4 --ras-entries 4
```

先做短测时将 `--scale train` 换成 `--scale test --verify-observer`。
IPC 用相同计时窗口的退休指令数除以 CPU 周期数。最新分支研究仅重跑了 test，
不能把旧 train 成绩当成本次固定版的新测量。
MicroBench 原生 SoC delayer 仍有提前 ARVALID 影响等待换算的已知局限；定时器秒数
属于该模型。主选型使用 AR 接受后计时的独立 100 ns/10 ns 存储模型，详见
[计时规则](../verification/MICROBENCH_TIMING_RULES.md)。

## 研究记录和保留范围

从[前端研究索引](../learning/FRONTEND_RESEARCH_INDEX.md)开始阅读：问题、论文/作者项目、
模型、RTL、验证、简单对照、面积时序、退化与不采用原因均保留。最终选择不以新算法的
复杂程度为目标，而按预先约定的整核面积×执行时间及单项退化限制判断。

远程保留源码、配置、测试、第三方许可证、研究笔记、精简比较表及依赖恢复文件。
`npc/result/`、编译缓存、波形、原始日志、软件镜像、网表和历史快照压缩包不在本次树中。
历史文档中的结果路径用于说明测量来源，不代表远程保存该文件；历史审计脚本需要
完整历史归档；2026-09-24 已按要求清理本机 result 中的原始产物，仅保留综合工具入口。
源码可用于新实验，不能将缺少历史产物说成已完成第二次独立复现。
已存在于旧提交的文件不改写历史删除，避免破坏已有分支引用。
