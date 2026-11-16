# 设备延迟模型验收（2026-09-28）

采用 `device-clock-v1`，原理与电路见[设备模型](../interconnect/DEVICE_TIMING_MODEL.md)。
本轮只改 SoC 设备推进、协议桥及仿真入口；没有修改 CPU RTL、频率、面积或 CLINT 换算。
旧工作区已有的 CPU、RV32IM 和探索改动保留，未提交或推送远程。

## 正确性与时间

五组 CPU 频率 100/200/250/580/720 MHz、设备 100 MHz，共 20 组回归全部通过：

- APB：每组 65 次访问，零/多等待、读写/字节选通、错误、连续请求及访问中复位；副作用只发生一次。
- AXI：每组 19 次完整事务，伪随机地址/数据/响应反压、AW/W 不同先后、ID/RESP/LAST；
  32-beat 读填满 16 项缓冲并环绕，未完成 R/B 同时存在时复位，然后重新访问。
- 共享 SDRAM 仲裁反例：每组分别提前发读和等写完成后发读，检查结果数据与响应时间。
- 实际 SDRAM 控制器和颗粒：短 burst、BL8、多段 burst、边界拆分及数据顺序，
  初始化至少 100 us，空闲稳定刷新约 7.81 us。设备后台状态随设备时钟推进。

720 MHz 的共享仲裁反例：旧模型提前读第 123 拍返回、晚发读第 50 拍返回；
新模型分别在第 50 / 64 拍返回。时间戳从各测试的统一起点计算，
这是同一模型内改变发读时机的对照，不是把两次不同到达轨迹直接当作同一请求延迟。

测试开发中，首次把空闲刷新间隔直接判成严格周期，遇到 778 拍而非 781 拍。
原因是读访问留下的打开行使首次刷新先做 precharge；后一次刷新没有这项工作。
保留失败日志，改为在关闭行工作排空后检查周期；没有修改 SDRAM 时序或删除硬件断言。

历史模型的读通道回归与 32 项写校准用例也通过，兼容入口保留原行为。

## 相同镜像的完整 SoC 短测

RV32I / 720 MHz，I-cache 1 KiB、4-way、32 B line、policy13；D-cache 256 B、2-way、16 B line；
BHT16、BTB16/2-way、RAS4。MicroBench test 十项通过，观察器开/关的输出、计数和架构摘要一致。
镜像哈希一致。CPU 源码差异只有 package 显式导入已有的 `MULDIV_ENABLE`；
两次均关闭 M，没有数据通路或控制逻辑变化，差异文件随结果归档。

| 窗口 | 旧响应缩放模型 | 新设备节拍模型 |
| --- | ---: | ---: |
| Total 时间 | 6.567 ms | 3.854 ms |
| Total 周期 | 4728464 | 2774833 |
| Total IPC | 0.163614 | 0.299830 |
| Scored 时间 | 2.242 ms | 1.512 ms |
| Scored 周期 | 1616057 | 1088342 |
| Scored IPC | 0.266273 | 0.395384 |

D-cache 平均 clean miss 从 83.612 拍变为 85.390 拍，
dirty miss 从 488.508 拍变为 151.127 拍。
主要修正落在写回与读回填重叠的路径；设备自身服务参数保持原值。
Scored 的退休指令均为 430313；Total 包含 UART 打印和状态轮询，设备运行节奏变化时，
轮询执行次数可以变化，因此不要求 Total 退休数完全相同。

每个独立计时窗口的 CLINT 与周期换算误差小于 1 us；Scored 是十个窗口之和，
允许累积各窗口的微秒量化误差。Total 和 Scored 使用各自的退休数与周期，不能互换。
结果变化属于模型修正；没有重跑 train，也不从 test 比例外推 train 成绩。

## 复现及证据

```sh
python3 npc/scripts/test_device_timing.py --output npc/build/tests/device-timing
make -C npc test-soc-timing
python3 npc/scripts/run_microbench_perf.py --isa rv32i --scale test --cpu-mhz 720 \
  --timing-model device-clock --verify-observer \
  --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 \
  --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 \
  --direction-policy 0 --history-bits 4 --ras-entries 4
```

SoC 连接须由 `make -C ysyxSoC verilog` 生成。此工作树原未初始化 Rocket Chip，
本轮借用本机同一 commit 的依赖完成生成：`d0c6b50fdefcdbe121e9788433ea51f7efaf1d32`，
未修改依赖源目录；新环境先按工程正常流程初始化子模块。

机器可读结果：[summary](data/device-timing-2026-09-28/summary.json)、
[20 组回归](data/device-timing-2026-09-28/unit-matrix.json)、
[日志哈希索引](data/device-timing-2026-09-28/logs.json)。
同目录保留新旧 report、manifest 和本轮基线源码哈希；原始日志根目录为
`npc/result/device-timing-20260928`。旧并发错误的原始数据在
`data/timing-audit-2026-09-28`。

## 边界

该模型保留当前控制器的周期、仲裁、行状态与刷新行为；跨频率桥为理想数字事件桥，
不是实际异步 CDC 或硅上实测。没有为提高分数减小 SDRAM 等待参数。
若更换真实存储器、CDC 或 PHY，必须使用对应参数重新验证。
RV32IM 580 MHz 整机编译曾启动，为控制并发资源在仿真前中止，未作为通过项；
580 MHz 的协议与实际 SDRAM 定向检查已通过。本轮完整 SoC 短测仅覆盖上述 RV32I 配置。
