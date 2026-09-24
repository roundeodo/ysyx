# 从 RV32 面试分支同步前端配置

日期：2026-09-24。目标为 `ysyx-workbench/npc` 的 `rv64-edge-ai`，仍是 RV64 顺序核。

## 采用的配置

| 项目 | 同步前 | 同步后 |
| --- | --- | --- |
| I-cache | 4 KiB、2 路、64 B 行、轮转替换 | 1 KiB、4 路、32 B 行、分段访问 RRIP（策略 13） |
| BHT | 16 项、每项 2 位、PC 索引 | 保持一致 |
| BTB | 总计 16 项、2 路、轮转替换 | 保持一致 |
| RAS | 4 项，解析后更新 | 保持一致 |

配置依据是兄弟仓库 `ysyx-workbench-rv32-interview/npc` 的：

- `configs/rv32-balanced.mk`：2026-09-24 固定的最终预设。
- `docs/verification/ICACHE_SELECTION_2026-09-21.md`：2026-09-22 完成的缓存选型。
- `docs/verification/BRANCH_HISTORY_EXPLORATION_2026-09-24.md`：完成较强方向预测比较后，继续选择 BHT16／BTB16 两路／RAS4。

源预设还包含 D-cache 参数和仿真频率。本次按请求同步 I-cache 与分支预测选择，
目标 D-cache 继续使用 4 KiB、2 路、64 B 行，整数位宽与 AXI 数据位宽继续为 64。
源分支的 720 MHz、整核面积和性能排名属于其 RV32 设计及测试环境，未作为 RV64 指标。
本次没有完成 RV64 负载选型、综合或 STA，不能据此宣称该配置是 RV64 的最优选择。

## 实现与兼容处理

默认参数统一写入 [Makefile](../../Makefile)，策略宏同时传入 Verilator 和 Slang。
构建与 STA 输出目录包含策略编号，避免不同替换策略共享旧产物。

新增 [riscv_icache_replacement](../../vsrc/riscv/core/frontend/riscv_icache_replacement.sv)，
从源模块中提取策略 13 的实际状态与逻辑；其余实验策略没有引入。
原轮转逻辑保留为策略 0。新模块同时进入仿真和综合 filelist。
查询快照、同组命中前递、分配事件与源策略一致，详见[电路说明](../microarchitecture/ICACHE_REPLACEMENT_DESIGN.md)。

目标缓存仍逐组清除有效位，因此在失效完成时复位替换状态；保持现有回填、提前响应和
失效时序。没有搬入源分支的零等待 miss 旁路或单拍全失效。分支预测器保留目标现有查询
和训练流水；本次同步的是最终容量和已选算法，不是两份前端实现的逐文件覆盖。

## 使用与复查

```bash
cd /home/yong/ysyx/ysyx-workbench/npc
make lint-npc test-config
make test-icache test-icache-replacement
make regression-rv64-isa
```

恢复旧缓存参数作独立对照时，四个参数需同时指定：

```bash
make build-npc NPC_ICACHE_CAPACITY_BYTES=4096 NPC_ICACHE_WAY_COUNT=2 \
  NPC_ICACHE_LINE_BYTES=64 NPC_ICACHE_REPLACEMENT_POLICY=0
```

单路配置需显式选择策略 0。替换模块测试使用独立 Python 缓存模型产生逐次 miss／替换路
参考值，再由 RTL 重放，覆盖连续行内访问、跨行重用、冲突、同拍命中前递、反压及失效。
`scripts/test_icache.py --reference-rtl <源模块路径>` 可让源策略 13 重放相同参考序列。
缓存与 AXI 集成测试另外检查返回数据、请求身份、不同字节通道、回填错误和失效排空。

## 本次结果

验证进行中；完成后在此记录实际结果。
源码来源哈希、修改前文件和日志保存在
`result/verification/frontend-sync-20260924/`。本次不修改源仓库，也不改写历史实验结论。
