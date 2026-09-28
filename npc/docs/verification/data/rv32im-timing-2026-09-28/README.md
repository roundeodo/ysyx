# RV32IM 时序优化证据

- `summary.json`：所有候选的面积、通过/失败频点、四类时序、同镜像周期比较及验证范围。
- `ppa/`：逐候选的完整命令、RTL 哈希、mapped cell 统计和 STA 数字。
- `baseline.json`、`baseline.diff`：修改起点。commit 加这些未提交差异才是本轮基线。
- `final-regression/`：最终源码对应的单元、整核、地址等价、异常及 FENCE 结果。
- `interrupt-640.log`、`address-configs.log` 及各 `*-final.log`：通过摘要与真实构建命令。
- `baseline-sim/`、`mac-sim/`：优化前后整核仿真构建命令及点积统计。
- `kernel-images/`：对应软件镜像；两边镜像 SHA256、周期、退休数一致。
- `tool-constraint-hashes.json`：工具、库、约束和构建入口哈希。
- `raw-log-index.json`：本地原始日志、源码快照和报告位置。大日志压缩为 gzip，生成的编译对象已清理。

复现入口为 `npc/scripts/measure_execute_ppa.py`、`test_address_add.py` 及现有 Make 回归目标。
具体电路取舍和测量限制见上两级 `RV32IM_TIMING_2026-09-28.md`。
