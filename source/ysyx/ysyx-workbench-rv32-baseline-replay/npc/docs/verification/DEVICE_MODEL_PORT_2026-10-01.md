# RV32I 前端研究分支：设备模型移植

CPU 基线为 fbe7824；模型来自 fd4ea6e 所引用的 ysyxSoC 提交 9b9682ed14bbed95f064f8351eaad6239c555089。
CPU RTL 未修改，不包含乘除法器、Issue、Scoreboard、ROB 或双槽 LSU。
六个设备模型和 Scala 接线文件逐字匹配来源，SoC 顶层重新生成；依赖补丁及生成文件哈希已更新。

默认 device-clock-v1：CPU 频率可配置，完整 SDRAM 控制器和 APB 外设按 100 MHz 设备事件节拍运行。
CLINT 仍按 CPU 频率生成微秒计数；不重复缩放设备响应延迟。
跨域连接仍是假定理想同步事件桥，不是可流片的异步 CDC。
`--timing-model legacy` 仅用于旧模型对照。当前 RV32I 脚本不接受后续 RV32IM 的 `--isa` 参数。

配置检查和 RTL lint 通过；100/250/720 MHz 各 APB、AXI 压力、共享 SDRAM 读写和 SDRAM 设备测试，共 12 组通过。
legacy 写突发校准四个频率比、每比八种等待组合，共 32 组通过。8 项产物生命周期测试通过。
原始日志及模型源码哈希索引见 data/device-model-port-20261001。
独立测试的生成对象已经删除；性能入口固定使用 result/performance/current，成功后保留小型历史报告。

历史 DEVICE_TIMING_2026-09-28.md 为来源版本验证记录，不代表本次重新测得的成绩。
本次不重跑综合：没有修改 CPU 电路，不能把设备延迟模型变化当作面积、频率或 CPU 微架构收益。

完整 SoC 验证：RV32I、720 MHz、MicroBench test 十项通过，观察器开/关输出、计数和架构审计一致。Total 0.003854 s、IPC 0.299829936；Scored 0.001512 s、IPC 0.395383988。未运行 train。测试完成后脚本只对 manifest 字段缩进作 AST 等价排版；RTL 未变化。
