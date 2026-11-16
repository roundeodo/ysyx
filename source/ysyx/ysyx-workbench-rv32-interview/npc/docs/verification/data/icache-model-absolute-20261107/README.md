# I-cache 模型绝对缺失率：历史结果恢复

2026-11-07 从本地 Git 提交 `5493a6aec976f4f9bdc075834d3f1202b0ae16ef`
恢复了原 `icache-selection-20260922/model/` 的六份 CSV、模型运行清单及相对 miss 汇总。
当前工作树已经不含这些原始 CSV，但 Git 历史仍保留；本次没有重新运行负载或 Cache 模型。
八份恢复文件的 SHA256 均与该提交中原归档 manifest 的记录一致，见 `provenance.json`。

每份 CSV 含 910 个结构/策略组合，原始整数访问数和 miss 数均完整保留。
本目录默认报告固定 1 KiB、4 路、32 B 行的 14 个策略，包含只能用于离线上界的 OPT。
六项输入是 JSON/BPE、量化装载、runtime 图的开发种子 41/73；不是 MicroBench train。
数据来自测量窗口内的退休 PC，模型逐负载冷启动，不含错误路径取指、实际回填等待或 IPC。
最终 RTL 策略 13 的算法对应模型 `burst_rrip`；其查询旁路属于电路实现，不另改变模型算法。

绝对缺失率 = miss 次数 / 访问次数。报告同时给出：

- 合并缺失率：六项 miss 求和 / 六项访问数求和，共 855,188 次访问。
- 等权平均缺失率：六项各自绝对缺失率的算术平均。
- 逐负载缺失率与整数计数：`per-workload.csv`。
- 原先使用的相对 PLRU miss 比几何平均，用于交叉核对，不替代绝对缺失率。

所有 14 个策略重新汇总的相对结果与原 `policy-screen-1k4way32.json` 一致，容差 1e-12。
分段 RRIP 合并缺失率 1.508908%，PLRU 1.719388%，SRRIP 1.824043%。
相对 PLRU 的合并 miss 减少 12.24%，等权相对比几何平均减少 9.57%；二者的负载权重不同。
这些结果不能直接换算成执行时间或 IPC 收益。

从仓库根目录重新生成报告：

```sh
python3 npc/scripts/report_icache_model_miss_rates.py \
  --input npc/docs/verification/data/icache-model-absolute-20261107/model \
  --output npc/docs/verification/data/icache-model-absolute-20261107 \
  --reference npc/docs/verification/data/icache-model-absolute-20261107/policy-screen-1k4way32.json
```

报告见 [REPORT.md](REPORT.md)，机器可读数据见 `absolute-miss-rates.json` 与 `summary.csv`。
原始 CSV 也可用同一脚本的 `--bytes`、`--ways`、`--line` 查看其他已扫描结构；
与当前历史相对汇总交叉检查时须保持默认的 1024/4/32 结构。
