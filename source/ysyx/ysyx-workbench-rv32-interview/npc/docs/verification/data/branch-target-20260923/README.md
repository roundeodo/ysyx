# 分支目标存储探索数据

> 本分支仅保存研究摘要；文中原始日志、镜像和快照路径是历史来源，原始 result 已清理，详见[发布范围](../README.md)。

开发与保留输入中U16小幅改善面积×时间；跨64 KiB调用退化，通用默认保持B0。
`summary.json`、`comparison.csv`给出结果；`evidence`保留配置、逐项测量、验证和资格检查。
`raw-log-index.json`绑定本机原始日志，包括失败尝试；STA原始文件以校验过的tar.gz保存。
`source-snapshots.tar.gz`含最初基线、实际RTL候选和最终执行脚本；`software-images.tar.gz`含软件输入。
复现入口为 `npc/scripts/reproduce_target_storage.py`；先执行 `--root <原始实验目录> --check-only`。
本目录不包含新的MicroBench train结果。
