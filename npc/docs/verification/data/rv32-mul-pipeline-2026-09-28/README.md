# 乘法流水的小型证据

- `summary.json`：同频与各自合法频点结果、PPA、验证边界和取舍。
- `source-hashes.json`：任务入口哈希及最终综合快照与当前 RTL 的绑定。
- `regressions.json`：最终启用断言的回归命令、状态和日志位置。
- `raw-log-index.json`：原始日志/报告路径、大小和 SHA-256。

原始产物在 `npc/result/mul-pipeline-20260928/`。只保留必要日志、报告、镜像、
仿真器和源码快照；可再生的对象目录可删除，综合大文件按候选存为 `sta.tar.gz`，
解压到对应候选目录即可恢复 `sta/`。完整实验说明见上级的乘法流水验证记录。
