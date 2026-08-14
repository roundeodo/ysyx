# NPC微架构实验日志

本文件只允许追加。每个结果必须记录Git commit、构建配置、工作负载、精确命令和相关
架构决策。若某项结果后来被证明无效，应追加一条记录解释原因，不能删除旧记录。

## 结果模板

### YYYY-MM-DD - <实验名称>

- Commit：`<完整commit hash或uncommitted>`
- 架构决策：`<Dxxx>`
- 工作负载和规模：`<名称>` / `<规模>`
- 构建配置：`<重要参数和功能开关>`
- 命令：`<精确命令>`
- 功能结果：`<pass/fail和trap状态>`
- 综合目标/结果：`<工艺、目标时钟、WNS/TNS/面积等>`

| 指标 | 数值 |
| --- | ---: |
| 活动周期 | |
| 退休指令数 | |
| IPC | |
| I-cache lookup/hit/miss | |
| I-cache命中率 | |
| IFU平均响应延迟 | |
| IFU响应等待周期 | |

分析：

- 说明相对上一条可比较记录发生了什么变化。
- 指出测得的主要瓶颈。
- 分开记录测量事实和待验证假设。
- 给出能够证实或否定假设的下一项实验。

## 2026-07-30 - 接入I-cache前的microbench基线

- Commit：uncommitted；在正式比较前必须基于已提交版本重新运行并追加基线记录。
- 架构决策：当前计划P1开始之前（历史计划D024之前）。
- 工作负载和规模：microbench / test。
- 构建配置：ysyxSoC校准延迟环境，未实现I-cache。
- 命令：历史运行；基于commit重新运行时必须记录准确命令。
- 功能结果：正常结束并输出性能统计。
- 综合目标/结果：本次运行不包含综合结果。

| 指标 | 数值 |
| --- | ---: |
| 活动周期 | 118,497,980 |
| 退休指令数 | 821,857 |
| IPC | 0.006936 |
| IFU请求/响应/交付 | 821,857 / 821,857 / 821,857 |
| IFU平均响应延迟 | 136.645 cycles |
| IFU AR反压周期 | 5,373,567 (4.535%) |
| IFU响应等待周期 | 112,302,555 (94.772%) |
| LSU load平均延迟 | 79.295 cycles |
| LSU store平均延迟 | 59.978 cycles |

分析：

- 前端响应等待区间占活动周期的94.772%。
- 第一项I-cache实验必须使用相同工作负载和延迟配置进行比较。
- 核心验收指标是更少的IFU响应等待周期和更高的IPC，并使用cache hit/miss/refill
  计数器解释变化原因。
- 由于没有记录commit和准确命令，本条记录不可完全复现，只保留为初步基线。

## 2026-08-13 - P1 I-cache独立NPC基本功能检查

- Commit：待提交工作树，基于`22f2b42ca794b2c4d7dc84b8f4c74d56304ed3c9`；提交后追加
  可复现commit记录。
- 架构决策：P1、D004、D005。
- 工作负载和规模：cpu-tests dummy / 13条退休指令。
- 构建配置：独立NPC，8 KiB、2-way、32 B line、blocking miss、AXI4 refill、I-cache启用。
- 命令：`make sim-npc PROJECT=riscv32 IMG=../am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin`
- 功能结果：pass，`HIT GOOD TRAP`，结束PC为`0x80000030`。
- 综合目标/结果：本次运行不包含综合结果。

| 指标 | 数值 |
| --- | ---: |
| 活动周期 | 71 |
| 退休指令数 | 13 |
| IPC | 0.183099 |
| IFU请求/响应/交付 | 17 / 16 / 13 |
| IFU平均响应延迟 | 2.500 cycles |
| IFU AR反压周期 | 14 (19.718%) |
| IFU响应等待周期 | 40 (56.338%) |
| IFU下游反压周期 | 1 (1.408%) |
| IFU丢弃错误路径响应 | 3 |
| LSU请求/完成 | 1 / 1 |

分析：

- 该结果证明当前活动RTL能够经过I-cache和fetch buffer完成基本程序，并正确丢弃redirect
  后的错误路径响应。
- dummy太短，不能用其IPC、命中率或平均延迟判断I-cache性能，也不能覆盖替换、early
  restart、错误refill和`fence.i`。
- 下一项实验是在提交版本上重跑相同命令，并完成I-cache定向测试和microbench A/B。

## 2026-08-13 - P1 I-cache提交版本复验

- Commit：`ce27fb8eed29c0b039dc11ddc66407c096486a16`。
- 架构决策：P1、D004、D005。
- 工作负载和规模：cpu-tests dummy / 13条退休指令。
- 构建配置：独立NPC，8 KiB、2-way、32 B line、blocking miss、AXI4 refill、I-cache启用。
- 命令：`make sim-npc PROJECT=riscv32 IMG=../am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin`
- 功能结果：pass，`HIT GOOD TRAP`，结束PC为`0x80000030`。
- 静态检查：`make lint-npc PROJECT=riscv32`和`make lint-soc PROJECT=riscv32`均通过；
  剩余信息为未使用地址常量和ysyxSoC既有时序风格警告。
- 综合目标/结果：本次运行不包含综合结果。

| 指标 | 数值 |
| --- | ---: |
| 活动周期 | 71 |
| 退休指令数 | 13 |
| IPC | 0.183099 |
| IFU请求/响应/交付 | 17 / 16 / 13 |
| IFU平均响应延迟 | 2.500 cycles |
| IFU AR反压周期 | 14 (19.718%) |
| IFU响应等待周期 | 40 (56.338%) |
| IFU下游反压周期 | 1 (1.408%) |
| IFU丢弃错误路径响应 | 3 |
| LSU请求/完成 | 1 / 1 |

分析：

- 该记录把P1基本功能检查绑定到确定提交，可由相同命令复现。
- 结果只证明最短控制流、一次store、redirect响应丢弃以及I-cache基本取指路径可工作；P1仍需
  I-cache定向测试、完整功能回归、microbench A/B和综合/STA后才能关闭。

## 2026-08-14 - P2配置层和宽度解耦收口

- Commit：uncommitted；P2提交后应把本字段替换为确定commit。
- 架构决策：P2，core宽度和AXI宽度只在adapter边界转换。
- 工作负载和规模：64/32位宽度adapter定向测试、35项RV32 cpu-tests、dummy DiffTest。
- 构建配置：`YSYX_RV32_BASELINE`；adapter单测额外启用64位core/32位AXI测试配置。
- 命令：`make test-width-adapter PROJECT=riscv32`、`make lint-npc PROJECT=riscv32`；
  cpu-tests逐镜像运行；DiffTest使用standalone内存配置的临时NEMU reference。
- 功能结果：adapter测试通过，lint通过，cpu-tests 35/35通过，dummy DiffTest通过。
- 综合目标/结果：本次变更不包含新的综合/STA结果。

验证范围：

- adapter覆盖64位读写拆成两个32位beat、窄写strobe、AW/W独立反压和响应保持；
- 覆盖读beat错误、第二个读beat错误和写响应错误，均只向core返回一次错误；
- RV32完整cpu-tests证明宽度重构没有破坏现有指令行为；
- standalone DiffTest证明重构后的架构状态仍与NEMU一致。

分析：

- P2的主要风险不是算术逻辑，而是地址lane、strobe、burst终止和错误聚合边界；定向单元
  测试比仅运行短程序更能约束这些行为。
- ysyxSoC与独立NPC使用不同NEMU内存映射，不能复用同一个reference构建结果。后续应在
  P3回归脚本中把两种reference配置显式命名，避免环境配置被误判为RTL错误。
