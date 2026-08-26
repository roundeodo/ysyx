# 当前验证记录

状态：从RV64主线重新建立基线

最后更新：2026-08-26

## 1. 清理说明

旧记录混合了已废弃RV32配置、RV64迁移配置、不同cache容量、不同总线延迟和多个综合约束，
其中许多数值不能直接比较。本文件不再保留这些排行榜。需要追溯历史时使用Git提交，不把
过期数据继续作为当前架构依据。

当前唯一配置为`rv64-edge-ai`。后续实验必须从同一RTL、同一workload和同一约束重新记录。

## 2. 当前功能基线

需要持续验证的功能包括：

- RV64I整数运算和W类窄结果语义；
- Zicsr、Zifencei、trap、`mret`和机器态中断；
- valid/ready流水级、RAW前递、load-use停顿和精确flush；
- I-cache hit/miss、AXI burst refill、critical-word early restart和invalidate；
- D-cache load/store、byte strobe、writeback、refill、clean和uncached路由；
- BHT/BTB/RAS预测、redirect和旧epoch响应丢弃；
- 64位core AXI4与外部32位ysyxSoC边界转换。

## 3. 快速回归

在`ysyx-workbench/npc`目录执行：

```bash
make test-config
make test-idu
make test-exu
make test-lsu
make test-pipeline
make test-uncached
make test-dcache
make test-core-merge
make test-soc-width-converter
make test-privileged
make test-axi-delayer
make lint-npc
```

完整RV64回归：

```bash
make regression-rv64
```

正式记录前运行代表程序并启用DiffTest：

```bash
make sim-difftest IMG=<rv64-image.bin> REF=../nemu/build/riscv64-nemu-interpreter-so
```

## 4. 性能模型回归

以下模型保留并作为工程基础设施维护：

```bash
make cachesim-test
make branchsim-test
make test-axi-delayer
```

设计空间探索命令见[Cache设计空间探索方法](CACHE_DESIGN_SPACE_EXPLORATION.md)和
[控制流预测设计记录](../microarchitecture/BRANCH_PREDICTION_DESIGN_RECORD.md)。

## 5. 待建立的基线表

下一次功能回归全部通过后，按下表追加一行。没有实际命令输出时不填写估算值。

| commit | workload | retired | cycles | IPC | I$ MPKI | D$ MPKI | branch MPKI | Fmax | area |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 待测 | RV64 MicroBench test | - | - | - | - | - | - | - | - |

## 6. 分析规则

1. 先按停顿周期定位前端、RAW、控制恢复、LSU、I-cache和D-cache瓶颈。
2. 只对占比足够高的瓶颈提出结构修改。
3. 模型用于预测趋势，RTL计数器用于确认真实收益。
4. PPA与性能必须对应同一commit；不使用旧面积或旧频率解释新RTL。
5. 面向AI目标的最终结论必须加入tokenizer、GEMV、KV cache和runtime queue代理负载。
