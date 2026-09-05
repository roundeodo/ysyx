# 验证记录与当前待办

状态：保留历史结果；当前能力与待办按源码核对

文档更新：2026-09-05

2026-09-05 先完成文档与源码核对，随后进行 RTL 目录、命名与排版整理。两次工作的范围
分别见第 7 节和第 10 节。下方 2026-08-26 的结果保留为历史记录，不与本次结果合并。

## 1. 历史清理说明（2026-08-26）

旧记录混合了已废弃RV32配置、RV64迁移配置、不同cache容量、不同总线延迟和多个综合约束，
其中许多数值不能直接比较。本文件不再保留这些排行榜。需要追溯历史时使用Git提交，不把
过期数据继续作为当前架构依据。

当前唯一构建配置为 `rv64-edge-ai`。名称不表示已经支持 AI 推理。后续每项测量应记录
自己的 RTL、软件和工具约束；比较版本时明确改动变量，控制其他条件。

## 2. 当前回归范围

需要持续验证的功能包括：

- RV64I 整数运算，以及 W 类指令产生 32 位结果再符号扩展到 64 位的行为；
- Zicsr、Zifencei、同步异常入口和 `mret`；机器态中断须接通后新增测试；
- `valid/ready` 流水级、相关与前递、load 后使用的停顿，以及错误路径清除；
- I-cache 命中、缺失、突发回填、所需字提前返回和失效；
- D-cache 读写、字节使能、脏行写回、回填、维护和 uncached 路由；
- BHT/BTB/RAS 预测、重定向和旧 epoch 响应丢弃；
- 64 位 core AXI4 与外部 32 位 ysyxSoC 数据接口转换。

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

2026-08-26完成RV64主线清理后已验证：

- `test-config`、`test-idu`、`test-exu`、`test-lsu`和`test-pipeline`通过；
- `test-uncached`、`test-dcache`、`test-core-merge`和`test-soc-width-converter`通过；
- `test-privileged`、`test-axi-delayer`、`cachesim-test`和`branchsim-test`通过；
- `lint-npc`通过，仅保留未使用字段等非致命告警；
- standalone RV64仿真器构建成功，`dummy-riscv64-npc.bin`命中good trap。

这组历史结果只覆盖当时运行的检查，不作为正式性能或 PPA 基线。特别是 `test-privileged`
通过不能证明整核响应中断，因为当前中断输入、待处理状态和接受路径尚未接通。

当前 RV64 集成回归入口：

```bash
make regression-rv64
```

该目标运行其依赖的配置测试、lint、构建和指定 ISA 程序，不代表覆盖所有 RV64 扩展。
当前 Makefile 没有在该目标中自动运行 `test-soc-width-converter`、`test-axi-delayer`、
`cachesim-test` 或 `branchsim-test`；涉及这些部分时需另外运行对应命令。

正式记录前运行代表程序并启用 DiffTest。将 `IMG` 替换为实际镜像路径，并确认参考模型已构建：

```bash
make sim-difftest IMG=/path/to/rv64-image.bin REF=../nemu/build/riscv64-nemu-interpreter-so
```

## 4. 性能模型回归

以下模型保留并作为工程基础设施维护：

```bash
make cachesim-test
make branchsim-test
make test-axi-delayer
```

配置比较命令见 [缓存配置比较方法](CACHE_DESIGN_SPACE_EXPLORATION.md) 和
[分支与跳转预测设计](../microarchitecture/BRANCH_PREDICTION_DESIGN_RECORD.md)。

## 5. 待建立的基线表

在声明范围的功能回归通过后，按下表追加实测结果。没有命令输出的项目写“未测”，
不填写估算值。每行附完整配置、输入、命令和原始输出路径；未提交版本另存补丁或源码
快照及校验值，仅有 commit 不能标识当前有修改的工作区。

| commit | workload | retired | cycles | IPC | I$ MPKI | D$ MPKI | branch MPKI | Fmax | area |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 待测 | RV64 MicroBench test | - | - | - | - | - | - | - | - |

## 6. 分析规则

1. 按停顿事件区分取指不足、操作数相关、控制恢复、LSU 等待与缓存缺失。事件可能同拍
   发生；未定义互斥分类时不能直接相加，也不能把其总和当成全部周期。
2. 性能优化先定位瓶颈；为学习或实现新功能增加结构时，先说明机制目标与验证方法。
3. 模型用于预测趋势，RTL计数器用于确认真实收益。
4. 每个版本的面积、时序与周期对应自己的 RTL；不使用旧面积或旧频率解释新 RTL。
5. M1～M3 先使用普通程序与定向测试；AI 负载和系统能耗在应用阶段再评估。

## 7. 2026-09-05 源码核对发现

以下是前一次文档核对发现的限制。后续命名整理没有改变这些硬件行为；验证入口的变化
另行记录，不能据此推断限制已经解决。

| 项目 | 源码中的情况 | 后续动作 |
| --- | --- | --- |
| 机器态中断 | `riscv_core` 无中断输入；CSR 的 `mip` 固定读零；commit 的 `trap_is_interrupt` 固定为零 | 接通中断源、状态与接受路径，再做整核中断测试 |
| `fence.i` 维护错误 | D-cache 输出错误标志，core 仅用仿真断言检查 | 明确并实现硬件错误处理，再注入写回失败验证 |
| 物理地址 | `PADDR_WIDTH` 与 `MEM_AXI_ADDR_WIDTH` 均为 32 | 记录当前 4 GiB 地址空间限制，应用需要更大内存时再扩展 |
| I-cache 提前返回 | 从行首进行 4 B 窄传输，所需字到达即返回；缺失期间仍阻塞新查找 | 区分提前返回、关键字优先传输和缺失期间命中，分别测试 |
| 缓存模型 | 模型采用 LRU，RTL 当前采用轮转替换 | 比较时注明策略；按每次目标缺失分类 3C |
| 形式验证 | 前一次检查发现旧 `YSYX_RV32_BASELINE` 标记；本次已移除，并发现测试代码与当前模块端口不一致 | 按当前接口更新连接及性质，重新运行；本次失败结果见第 10 节 |

相关源码：
[core](../../vsrc/riscv/core/riscv_core.sv)、
[CSR](../../vsrc/riscv/core/riscv_csr_file.sv)、
[commit](../../vsrc/riscv/core/riscv_commit.sv)、
[配置](../../vsrc/riscv/common/riscv_config_pkg.sv)、
[I-cache](../../vsrc/riscv/core/frontend/riscv_icache.sv)、
[缓存模型](../../tools/cachesim/cachesim.cpp)。

## 8. 形式验证范围

当前入口是 `make formal-pipeline`，使用
[`riscv_pipeline_control.sby`](../../tests/formal/riscv_pipeline_control.sby) 和
[`riscv_pipeline_control_formal.sv`](../../tests/formal/riscv_pipeline_control_formal.sv)。
配置采用 BMC 模式、深度 20，检查取指缓冲顺序与冒险控制性质；不是整核或无界证明。

实际宽度由 `riscv_config_pkg` 定义。旧 RV32 宏名已移除，`.gitignore` 也已允许保存
`.sby` 文件。2026-09-05 运行时，Yosys 的 slang 前端报告冒险控制器的多处端口不存在，
尚未进入求解阶段。改名前快照在同一工具环境下报告相同的 7 个端口错误。

例如测试仍连接 `execute_uop_valid_i`，当前模块接口已经使用
`execute_instruction_present_i` 等更明确的条件。不能只替换端口拼写就宣称性质仍正确；
需要核对各输入的含义、约束和断言，再运行验证。

## 9. 当前阶段使用哪些程序

| 目的 | 可使用的程序或序列 |
| --- | --- |
| 指令语义 | RV64 指令定向测试、声明范围内的 cpu-tests 与 DiffTest |
| 前递与相关 | 连续依赖运算、同寄存器多次写入、load 后使用、独立运算 |
| 控制流 | 循环、连续分支、调用返回、间接跳转与异常返回 |
| 缓存与总线 | 不同工作集、步长和冲突地址，脏行替换，反压与错误注入 |
| 乱序机制 | 老指令等待时让年轻独立指令执行，检查执行顺序与退休顺序 |
| 多发射 | 同周期相关、资源争用、多个完成结果与提交边界异常 |

表中程序类型是测试计划，不表示每一项已有可运行程序。M1～M3 不以运行完整 AI 模型为条件。
