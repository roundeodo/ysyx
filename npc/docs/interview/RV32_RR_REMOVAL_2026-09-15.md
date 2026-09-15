# RV32：取消独立寄存器读级 RR

日期：2026-09-15。工作树：`ysyx-workbench-rv32-interview`，分支：`rv32-interview-20260911`。
源代码基点：`4d0716eb221ad49d4dd88890f6d2ddb7fdd11604` 加本次工作树改动。
本记录对应当前未提交的实现，不代表 GitHub 上的旧快照已更新。

同日后续又进行了 BHT/BTB/RAS 模块拆分，见
[预测器拆分验证记录](../verification/RV32_PREDICTOR_SPLIT_2026-09-15.md)。
本页保留取消 RR 时的原始测量，后续网表及频率以新记录为准。

## 1. 当前连接与选择

已经取消 `riscv32_core.u_register_read_stage`，现在的连接为：

```text
fetch buffer → 组合译码、GPR 读取、操作数选择/前递 → ID/EX → EXU
```

GPR 保留两个组合读端口和一个同步写端口。ID/EX 仍保存已经准备好的执行包，包含主项
和 skid 项；执行结果寄存级与 WB 也保留。删除的是 GPR 读取后、ID/EX 之前的独立 RR
寄存边界。旧 `riscv32_register_read_stage.sv` 文件保留供追溯，当前 core 没有实例化它。

优先减少多余寄存状态和指令传递延迟，频率按实际时序选择。本次采用 **750 MHz**，不再
以维持原来的 820 MHz 作为保留 RR 的条件。面积更小不自动意味着程序用时更短，见下方测量。

## 2. 为保证正确性同步处理的逻辑

- 未被 ID/EX 接收的指令留在取指缓冲，`valid` 和上游 `ready` 同时受冒险及中断停发条件约束。
  不会出现取指缓冲出队、ID/EX 却未保存该指令的情况。
- GPR 读取与前递持续按当前译码指令选择。同拍写回使用现有 WB 前递，之后读更新后的 GPR；
  因此移除了旧 RR 输入处重复的 WB 选择，也不再维护停顿中的 RR 操作数快照。
- 保留 EX、执行结果级、WB 的前递优先级及 load-use 等待。尚未完成的最近生产者仍会阻塞
  消费者，不能退而使用更老生产者的值。
- CSR 地址直接来自指令 `[31:20]`，与其余译码并行；访问使能仍由译码控制。
  CSR 指令仍串行化到提交，统一归为等待完成的生产者，去掉不必要的 CSR 合法性检查到
  EX 可前递标志寄存器的依赖。CSR 读值及非法访问标志仍传给 EXU，异常语义不变。
- 两项取指缓冲改为环形 FIFO。原实现出队时可能把备用指令搬到主槽，使译码/冒险产生的
  出队控制驱动宽数据 mux。现实现出队只改读指针，入队只写空闲槽位。
  代价是输出需要一个由寄存读指针控制的二选一 mux。容量仍为两项，无空队列穿透；
  满队列即使本拍出队也不接收新输入，保持原有反压规则。

仿真监视器的历史端口名 `register_read_valid_i` 暂时保留，现连接 `decoded_uop_valid`，
表示译码输入是否有指令；它不代表仍存在 RR。PMU 的前端供给等待也按新边界统计，
不要把新旧内部阻塞分类直接当作完全相同的事件。本次 IPC 使用退休事件与周期的被动计数。

## 3. 面积与综合后时序

配置为 `rv32-baseline`：I-cache 256 B / 1 路 / 16 B 行，D-cache 256 B / 2 路 / 16 B 行，
BHT 16 项、BTB 16 项 / 2 路、RAS 4 项。使用 Yosys/Slang、NanGate45 typical 标准单元库、
`DELAY 0` 策略和 iEDA/iSTA。边界为含复位控制器及复位缓冲树的纯核，不含 CLINT、SoC。

| 实现 | mapped cell area（μm²） | 约束频率 | 最差 setup slack | 说明 |
| --- | ---: | ---: | ---: | --- |
| 修改前，保留 RR | 78,163.036 | 820 MHz | +0.049 ns | 引用 2026-09-06 同边界历史测量，本次未重跑原版综合 |
| 本次移除 RR，仍用主/备用槽取指缓冲 | 76,811.490 | 820 MHz | −0.140 ns | 中间候选，出队控制到宽数据搬移成为瓶颈 |
| 最终实现，环形取指缓冲 | 76,585.656 | 820 MHz | −0.096 ns | 当前源码综合，未通过该频率 |
| 最终实现，同一网表降频 | 76,585.656 | **750 MHz** | **+0.018 ns** | setup、hold、门控时钟检查均通过 |

最终比修改前减少 **1,577.380 μm²，约 2.02%**。750 MHz 下最差 hold slack 为 +0.059 ns，
门控时钟 max/min slack 分别为 +0.101 / +0.097 ns；报告估算 Fmax 为 760.556 MHz。
这是理想时钟、未提取布线寄生的综合后估算，不是布局布线后的频率保证。

最终关键路径从取指 FIFO 的 `read_index_q` 寄存器，经输出选择、译码/操作数控制逻辑到
`u_decode_execute_stage.skid_execute_packet_q[72]`。因此不能将原来的时序失败简单解释为
“GPR 阵列读不够快”。本次选择 750 MHz 通过检查，未继续为更高频率增加流水级。

原始证据位于
[`result/performance/rv32-remove-rr-20260915`](../../result/performance/rv32-remove-rr-20260915/)：
[最终面积](../../result/performance/rv32-remove-rr-20260915/sta-ring/riscv32_core_reset_boundary-750MHz-buffered/synth_stat.txt)、
[750 MHz 时序](../../result/performance/rv32-remove-rr-20260915/sta-ring/riscv32_core_reset_boundary-750MHz-buffered/riscv32_core_reset_boundary.rpt)、
[820 MHz 时序](../../result/performance/rv32-remove-rr-20260915/sta-ring/riscv32_core_reset_boundary-820MHz-buffered/riscv32_core_reset_boundary.rpt)。

750 MHz 检查复用了 820 MHz 综合并加入复位树后的完全相同网表，仅更改时钟约束。
保存的 SDC 从环境变量 `CLK_FREQ_MHZ` 读取频率；不能只看 SDC 文件内容而忽略调用参数。

## 4. 功能验证

| 范围 | 结果与证据 |
| --- | --- |
| 最终实现的 Verilator lint | 完成；未出现组合环、锁存器或多驱动警告；仍有项目原有的其他警告，不能说零警告 |
| 流水线控制和取指 FIFO | 通过；新增 2,048 拍事务队列检查，核对 991 次输出、476 次同时入出队、34 次 flush；比较完整取指包 |
| 定时器中断完整系统 | 3 组汇编系统用例和 2 组 AM 系统用例通过，覆盖不同存储延迟 |
| CLINT、中断控制与 IFU 重定向 | 3 项 RTL 单元回归通过 |
| RV32 CPU DiffTest | 当前 checkout 中可用的 34 个 CPU 测试全部通过 |
| 特权/提交/PMU、EXU、复位及执行结果级 | 移除 RR 的首轮候选通过；之后只修改取指 FIFO，并重跑上述最终实现回归 |
| SoC MicroBench `test` | 最终实现、CPU 750 MHz，10 项 PASS、GOOD TRAP |

日志：[最终流水线/中断](../../result/performance/rv32-remove-rr-20260915/regression-ring.log)、
[34 项 DiffTest](../../result/performance/rv32-remove-rr-20260915/difftest-ring.log)、
[首轮模块回归](../../result/performance/rv32-remove-rr-20260915/regression.log)。
原计划列表中的 `csr-trap.c` 在此 checkout 缺失，因此没有计作通过；不能宣称 35 项全通过。
异步中断依靠系统定向用例检查，不将其表述为已经通过异步中断 DiffTest。

## 5. 750 MHz 下的低侵入性能测量

使用原生 MicroBench `test` 镜像，关闭额外 CSR 诊断读；由仿真侧在原生计时窗口边界记录
CPU 周期与退休事件。CPU 配置 750 MHz，设备延迟模型 100 MHz，本地 CLINT 在同一个输入
时钟下每 750 拍让 `mtime` 增加 1，即 1 MHz 计数。没有新增一个独立 100 MHz CLINT 时钟。

| 窗口 | CPU 周期 | 退休指令 | IPC | 原生计时器记录 |
| --- | ---: | ---: | ---: | ---: |
| Total，程序原生总计时窗口 | 4,828,640 | 763,521 | 0.158123405 | 0.006438 s |
| Scored，十项计分窗口之和 | 2,168,036 | 430,313 | 0.198480560 | 0.002891 s |

核对方式：`IPC = 退休指令 / 同窗口 CPU 周期`；`时间 = mtime 差值 / 1,000,000`。
周期除以 750 MHz 得到 Total 0.006438187 s、Scored 0.002890715 s，与定时器结果在
微秒分辨率内一致。Scored 是多个窗口之和，允许各次计时量化误差累加。
宿主运行耗时与上述 CPU 程序用时分开，不能混用。

原生 Total 不包含从复位开始的全部执行；本次从复位到退出的单独统计为 5,369,910 拍、
807,499 条退休指令、IPC 0.150374774。面试报 IPC 时必须说明对应哪个窗口。

旧版保留 RR、CPU 820 MHz 的同尺度被动测量为 Scored 0.002836 s、IPC 0.185076641，
Total 0.006309 s、IPC 0.147576450。本次计分用时约增加 1.94%，总计时约增加 2.04%。
降频同时改变设备延迟折算成的 CPU 周期，因此 IPC 变化不能全部归因于硬件结构优化；
本次没有取得新旧结构在同一频率下的完整 A/B。

完整原始计数、镜像、源码快照与哈希见
[本次 report.json](../../result/performance/rv32-remove-rr-20260915/microbench-final-750/report.json) 和
[manifest.json](../../result/performance/rv32-remove-rr-20260915/microbench-final-750/manifest.json)。
本次未重复观察器开/关一致性实验，报告中 `observer_on_off_verified` 为 false；
计时器与周期交叉检查已通过。**本次没有跑 `train`，不能沿用旧结构的 train 成绩。**

## 6. 后续运行命令

在面试工作树根目录运行短测：

```bash
python3 npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 750 \
  --output npc/result/performance/rr-free-test-750
```

需要手动运行长测时使用：

```bash
python3 npc/scripts/run_microbench_perf.py --scale train --cpu-mhz 750 \
  --output npc/result/performance/rr-free-train-750
```

输出目录必须尚不存在。脚本会同时设置 CLINT 分频和设备延迟换算，并保存可复核的报告。
脚本未指定频率时仍默认 820 MHz；当前版本应显式传 `--cpu-mhz 750`。

重跑功能回归时，先将环境指向面试工作树，避免误用主工作树的 RV64 文件列表：

```bash
export NPC_HOME="$PWD/npc"
export AM_HOME="$PWD/abstract-machine"
export NEMU_HOME="$PWD/nemu"
make -C npc git_commit= NPC_CONFIG=rv32-baseline \
  lint-npc test-pipeline test-privileged test-exu test-timer-interrupt test-timing
```

每次 `make` 显式传 `git_commit=`，防止旧的自动提交钩子修改仓库历史。
