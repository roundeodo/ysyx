# RV32IM 前端时序证据

结论与口径见[验证记录](../../RV32IM_FRONTEND_TIMING_2026-09-28.md)。

- `summary.json`：基线和全部候选的面积、四组 STA、最终选择与验证范围。
- `source-manifest.json`：本轮冻结起点及最终 RTL 哈希；只有 I-cache replacement 改变。
- `ppa/`：各候选映射命令、源码哈希、单元统计、实测频点与失败点。
- `replacement.json`、`icache.json`、`fetch.json`：最终源码的模型和接口测试。
- `regression.json`、`core.json`、`exception.json`：整核、异常、FENCE.I、中断命令及结果。
- `kernel.json`：相同软件镜像的周期、退休数、校验与镜像哈希；非 train 数据。
- `candidate-patches/`：从最终前端源码返回基线或重建拒绝候选的补丁；只用于隔离副本。
- `raw-index.json`：本地原始证据路径、大小、哈希；`cleanup.json`记录生成物清理和无损压缩。

原始目录为 `npc/result/rv32im-720-20260928`。保留起点、候选源码、日志、模型事件、
软件镜像和 STA 输入网表；删去本轮 Verilator 编译目录，大日志与网表以 gzip 保留。
需要直接重放某个旧 STA 命令时，先恢复其 `.netlist.v.gz`，或按验证记录从源码重新综合。
旧阶段的工具/约束证据在 `../rv32im-timing-2026-09-28/`，本轮沿用同一流程。
原始日志不需要提交；本目录保留便于版本管理的小型结果与索引。
