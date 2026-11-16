# Replay I-cache 扩容与 IPC 瓶颈

## 比较范围

仅在 `ysyx-workbench-rv32-baseline-replay` 测试；interview 工作区及默认配置未改。
Git 基点 `316d1d2`，硬件是已有工作区恢复的 `e3b018f` 旧核及随后接入的混合预测，
不是干净 HEAD。各次实际来源由证据目录的 `manifest.json` 哈希确认；接入源码快照见
[混合预测记录](RV32_REPLAY_HYBRID_2026-10-11.md)。本轮没有修改 RTL、计时模型或软件。

RV32I、单发射顺序、保留前递；CPU 700 MHz、设备 100 MHz、`device-clock-v1`。
CLINT 输出微秒计数；Total/Scored 的 IPC 分别使用对应物理采样窗口的退休数与 CPU 周期。
700 MHz 在本轮是仿真条件，未新增综合/STA 资格。

容量对照只改 256 B → 1024 B：一路、16 B 行、policy0，组数 16 → 64。
预测表、弱态 BTFNT、早期目标均关闭，D-cache 仍关闭。
既有参数即可生成这两种电路，无需添加模块、流水级、旁路或新状态。
I-cache 仍为同步查询、单个阻塞 miss、关键字提前返回；整行结束前不接受下一查询。
没有同时改为正式版的四路/32 B 行/policy13。

## 当前源码容量对照：test

两组软件镜像、完整来源哈希、计时和存储模型一致；十项结果全部通过，观察器开关的
输出、计数、架构 audit 各自完全一致。这里不是 NEMU DiffTest 或逐指令 A/B 等价证明。

| 无预测、无 D-cache | Total 周期 | Total timer | Total IPC | Scored 周期 | Scored timer | Scored IPC |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| I-cache 256 B | 6785149 | 9.693 ms | 0.118193425 | 3601628 | 5.146 ms | 0.119476803 |
| I-cache 1 KiB | 5009725 | 7.156 ms | 0.160098608 | 2747871 | 3.923 ms | 0.156596507 |

Total 周期减少 26.166%，同频加速 1.3544 倍；Scored 周期减少 23.705%。
Total 退休数 801960 → 802050，Scored 430311 → 430307。
计时采样位于 CLINT load 生效前沿，未强制退休到固定指令序号；Scored 的四条差异
未逐指令定位，因此不宣称两组窗口覆盖完全相同的退休流。保留原始样本及计数，不改参考值。

整程序 PMU 另一个窗口显示：miss 32672 → 10857，命中率 97.755% → 99.258%；
控制恢复等待 1879209 → 943503 拍，而 EX 纠错 190455 → 190472 次基本相同。
容量没有修正预测方向；它缩短了错误/实际跳转后重新供给指令的等待。
LSU 结构等待仍有 3175347 拍，占新整程序周期 56.517%，是更大的剩余限制。
这些 PMU 数值不能套入 Total/Scored 窗口相加。

本次单次 test 主仿真主机用时约 43～54 秒，另有编译及观察器关闭复跑。
不能用这组小输入结果代替 train 的容量收益。

## 用户完成的 train：预测器对照

两组都为 256 B/一路/16 B 行、D-cache 关闭，镜像 SHA256 相同：
`2d200997d01ec6417e1443f122f8b966a6000ea252399ddadb490aadf1e86bb6`。
各项 Scored 退休数一致，总计 186810325 条。

| train 配置 | Total timer | Total IPC | Scored timer | Scored IPC |
| --- | ---: | ---: | ---: | ---: |
| 无预测 | 2.711176 s | 0.140626041 | 1.899904 s | 0.140465930 |
| 接入正式混合预测 | 2.173550 s | 0.175434685 | 1.541265 s | 0.173150929 |

Total 周期减少 19.830%，Scored 减少 18.877%。整程序 EX 纠错
65744519 → 16610287（减少约 74.7%），错误路径响应 75904660 → 20940046，
I-cache miss 9405161 → 7036262。不能因命中率略降就认为预测使取指变差：
请求分母和错误路径流量都变了。

这是历史无预测核与混合预测接入的比较，不是当前源码只翻一个开关的 A/B。
除了必要 RTL 差异，Makefile 与性能脚本哈希也变了。旧的严格比较脚本因此拒绝它，
本轮未削弱该脚本检查。核对归档的前后源码发现这两个包装文件只改了默认参数、帮助和
合法性检查，测量/软件构建逻辑未改；其差异保存在 `reviewed-wrapper-diff.txt`。
软件、SoC 模型和 C++ 测量来源均相同。这一人工审查边界在机器结果中单独标注。

## 瓶颈与计数边界

| 整程序互斥发射槽归因 | 无预测 train | 混合预测 train |
| --- | ---: | ---: |
| 控制恢复 | 30.777% | 7.629% |
| LSU 结构等待 | 33.500% | 41.694% |
| 前端供给 | 13.806% | 27.209% |

无预测版同时受控制流恢复、数据访问和小 I-cache 限制。混合预测之后，LSU 结构等待
仍约 6.35 亿拍，基本没有下降，成为首要剩余来源。`data_mem` 在 D-cache 关闭时将允许的
访问送入 uncached 路径；hazard 在 LSU busy 且未成功交付时禁止年轻执行推进，
独立 ALU 指令也不能覆盖这段时间。load 平均约 35 个 CPU 周期，store 约 13 个周期。

前端也仍重要：混合预测 train 有约 704 万次 miss，关键指令平均约 71 拍才返回。
97.7% 命中率不等于 miss 代价很小。增容可降低容量/冲突 miss；本轮未分类二者，也未
证实具体 train 工作集是否适合直接映射 1 KiB。

计数器按恢复 > LSU > RAW > 串行化 > 前端归因；恢复直到目标进入 ID/EX 才结束，
所以恢复项包含期间的取指等待。前端子分类又优先记录请求反压，miss 常落入该分类，
因此 `I-cache miss service = 0` 不表示零 miss。IFU AR backpressure 记录的是
IFU/I-cache lookup ready 反压，不是仅 AXI AR 通道。
各类归因互斥但不是独立可消除成本；IFU 等待、AMAT 与 miss penalty 又存在重叠，
不能直接相加或据此声称某项优化的理论加速。

## 复跑与证据

在 replay 目录运行完整 train（不自动执行数小时任务）：

```bash
cd /home/yong/ysyx/ysyx-workbench-rv32-baseline-replay
python3 npc/scripts/run_microbench_perf.py \
  --scale train --cpu-mhz 700 --timing-model device-clock \
  --predictor-enable 0 --dcache-enable 0 \
  --branch-static 0 --early-target 0 \
  --icache-bytes 1024 --icache-ways 1 --icache-line 16 --icache-policy 0 \
  --output npc/result/performance/replay-icache1k-no-predictor-train
```

本次两个 test 使用相同命令，将 scale 改为 test 并加 `--verify-observer`，分别指定容量
256/1024 和输出 `replay-icache256-no-predictor-test` / `replay-icache1k-no-predictor-test`。
主机 train 历史用时约 3.1～3.7 小时，与 CPU 模型中的 2 秒量级执行时间不是同一指标。

证据目录 `data/replay-icache-capacity-20261011/` 保存四组 manifest/report、完整小型仿真日志、
计时样本、用户原文、包装源码差异和文件哈希。运行该目录的 `analyze.py` 可重建
`comparison.json`；原始结果的自动归档路径保存在各组 `retention.json`。
两次新构建成功后已自动清理大型编译产物。

1 KiB 无预测 train、此次综合/STA 和新的 NEMU DiffTest 均未运行。
没有将旧 256 B 面积赋给 1 KiB，也没有提交、推送或改变正式配置。
