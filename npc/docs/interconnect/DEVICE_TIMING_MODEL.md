# 设备延迟模型

当前默认：`device-clock-v1`，2026-09-28。CPU 频率由配置给出，设备域固定 100 MHz。
旧模型通过 `--timing-model legacy` 保留；新旧结果不能混作 CPU 架构优化收益。
实现与验证记录见[本轮验收](../verification/DEVICE_TIMING_2026-09-28.md)。

## 为什么更换

[一生一芯 B4 手册](https://ysyx.oscc.cc/docs/2407/b/4.html)要求校准 CPU 与 100 MHz
设备的速度差，介绍多时钟仿真和插入延迟器两条实现路线。AXI 需要计入地址等待、
每个读 beat 和每个写 beat，不能只延迟 B，也不能把计时起点移到 AR 握手来隐藏排队。

旧模型让设备每个 CPU 周期运行，再按频率比推迟回复。在实际共享 SDRAM 的路径中，
W 校准等待会阻挡 AR；读计时器随后又把这段等待乘一次频率比，导致提前读反而更晚。
[并发计时审计](../verification/TIMING_AUDIT_2026-09-28.md)保留了独立复现。
同时，设备初始化、刷新和空闲后台状态仍按 CPU 频率推进，单纯延后回复不能修正它们。

## 当前电路

连接由 `ysyxSoC/src/SoC.scala` 生成，Verilog 在 `ysyxSoC/perip/amba/`。

| 部分 | 推进时间与边界 |
| --- | --- |
| CPU、交叉开关、AXI→APB 桥、CPU 本地 CLINT | CPU 周期 |
| AXI 桥之后的完整 SDRAM 控制器 | 100 MHz 设备节拍 |
| APB 桥之后的 UART、GPIO、键盘、VGA、SPI、PSRAM | 同一 100 MHz 设备节拍 |
| SDRAM / SPI flash / PSRAM 仿真颗粒 | 对应控制器输出的引脚与时钟 |

`device_clock.v` 在 CPU 负沿更新相位累加器，每次累加 Fdevice；达到 Fcpu 时减去
Fcpu，并允许下一 CPU 正沿推进设备。使用整数 Hz，不再使用 1024 分母截断频率比。
设备事件相对理想时间的量化误差小于一个 CPU 周期，长期无比例漂移。
复位期间允许设备获得复位沿，释放后从确定相位开始。当前支持 Fcpu≥100 MHz。

这是数字事件节拍，不是模拟占空比模型。设备域必须整体改接该时钟，不能只减速桥而
继续让设备每 CPU 拍执行。外层不再额外乘频率比，避免二次校准。

### APB

电路顺序为请求选择与保存 → 设备 setup/access → 原路返回数据与错误：

- CPU setup 碰到设备沿时直接进入设备 setup；否则保存 72 bit 请求，等下一个设备沿。
- `SETUP`、`ACCESS` 只在设备节拍推进，设备自己的 PREADY 决定额外等待。
- ACCESS 完成沿同时返回 CPU PREADY；无额外结果流水级。访问只完成一次。
- 复位清空状态和请求；下一次访问重新经过 setup。

保留 setup 是 APB 协议要求；其余等待来自设备相位和设备服务，不按 benchmark 调常数。

### AXI

电路顺序为请求与事务归属 → 设备握手 → 响应缓冲/旁路 → CPU 握手：

- 保留一笔读、一笔写可并存的范围，AR/AW/W 无新增请求 FIFO。
  CPU 持有请求直到设备沿接受，AW 与 W 可以独立先后到达。
- 每个 W beat 都在设备沿传输；CPU 尚未提供数据的空档自然消耗物理时间，不再乘比例。
- R 保留 16 项响应容量，B 保留 1 项。保存完整 ID、数据、RESP 和 LAST。
  CPU 反压时保存一次，后续 payload 保持稳定；R 缓冲满时反压设备，出入队可以同拍。
- 空缓冲在设备沿直通，没有强制新增一拍响应等待。B 在地址和最后一个 W 均接受后才能返回。
- CPU 消费最后 R/B 后释放对应事务归属；复位丢弃缓冲和在途归属，与设备一起复位。

读写独立推进，但仍竞争原 SDRAM 控制器的共享资源。提前请求可以参与原控制器仲裁，
不会启动额外的“响应时间×比例”计数器。CPU 的 RREADY/BREADY 反压不会再次放大。
接口规则依据 [Arm AXI 规范](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)。

## 与真实系统的关系

SDRAM 保留原控制器和颗粒模型：100 MHz、READ_LATENCY=2，以及初始化、行状态、
tRCD/tRP/tRFC 和刷新逻辑。一个设备服务区间若实际耗费 k 个设备周期，其时间就是
k/100 MHz；以 CPU 周期观察约为 k×Fcpu/100 MHz，不随 CPU 频率错误地改变物理服务速度。
并发阶段可能重叠，不能把所有阶段耗时简单相加。

跨频率桥假设**理想同步事件传递**：请求等待设备接受沿，返回可在该沿被 CPU 接受；
没有模拟异步 FIFO 同步级、亚稳态、PHY、板级传播和 PVT。这是课程平台明确的数字模型，
不是可流片 CDC 实现，也不承诺等于某颗实物芯片的绝对延迟。若改成真实异步互连，必须
根据所选桥补充其实际队列和跨域延迟；不凭空统一添加或删去若干拍。

生成脉冲无需 Verilator `--timing`，可继续使用现有单顶层时钟驱动；
[Verilator 的多时钟说明](https://verilator.org/guide/latest/connecting.html)也允许外部安排时钟事件。
`--timing` 只用于本轮独立 SV 测试台。

## 配置与计时

- 性能脚本默认 `--timing-model device-clock`；Make 对应 `NPC_DEVICE_TIMING_MODE=1`。
- 历史入口 `legacy` / `0` 恢复单 CPU 时钟和原响应缩放；不能与新设备节拍叠加。
- 改完 Scala 连接须在 `ysyxSoC` 下执行 `make verilog`；仅更换 delay 模块文件不足以接通设备时钟。
- 模拟器构建目录带模式标识，manifest 保存模型版本、频率、缓冲深度、源码和镜像哈希。
- CLINT 未改：按配置 CPU 频率产生微秒计数；原生 Total/Scored 窗口、被动退休计数保持不变。
  仿真器/VCD 的时间步不直接作为物理 ns 使用；
  `时间=同窗CPU周期/Fcpu`，`IPC=同窗退休指令/同窗CPU周期`，并核对微秒取整误差。

完整使用方式见[MicroBench 计时规则](../verification/MICROBENCH_TIMING_RULES.md)。
