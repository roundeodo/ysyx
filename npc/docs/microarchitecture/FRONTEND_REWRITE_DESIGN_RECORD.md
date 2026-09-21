# RV32 前端：数据流与源码顺序

当前实现，2026-09-19。阅读入口；预测器和 I-cache 的内部细节分别在各自说明中维护。

## 取指怎样完成

1. **PC 与预测**：IFU 发出 PC；BHT、BTB、RAS 并行组合读取，预测器用一个响应寄存器
   保存 PC、epoch 和预测结果。IFU 接收预测后，把请求送入两项请求队列；队列为空时直接送到 I-cache。
2. **请求队列与 I-cache**：队首向 I-cache 发起查询。I-cache 同步读取 tag/data，
   命中直接返回；未命中由单个 miss 单元完成回填，关键指令字可以提前返回。
3. **响应与译码**：IFU 取出唯一在途请求的预测信息，丢弃旧 epoch 响应；有效指令通过两项
   fetch buffer，随后交给译码。空 buffer 可直通，译码反压时再保存指令。

预测训练是独立的反馈路径：从 EX 结果寄存器直接更新 BHT、BTB、RAS，不再经过训练寄存器。
上面的条目表示功能顺序，不表示三个固定流水级；实际周期边界由下表中的寄存器决定。

## 状态与保留理由

| 位置 | 保存内容 | 存在理由 |
| --- | --- | --- |
| IFU PC / epoch / tag | 下一查询地址、重定向代次、请求编号 | 连续发出请求，并识别过期响应 |
| 预测器响应寄存器 | PC、epoch、完整预测 | 隔开预测组合路径与 PC 更新，并在反压时保持结果 |
| IFU 两项请求队列 | 等待 I-cache 接收的地址、身份、预测 | 吸收反压；空队列直通，满队列出队时允许同拍入队 |
| IFU 在途预测上下文 | 唯一已接收、未响应的 I-cache 请求对应的预测 | 在指令返回时重新配对 |
| I-cache | 同步阵列输出、对齐请求、miss 上下文、响应和失效状态 | 见 [I-cache 说明](ICACHE_DESIGN_RECORD.md) |
| fetch buffer | 两项指令及读写指针、数量 | 吸收译码反压；没有额外的指令搬移级 |

redirect 更新 epoch 并清除年轻预测。已经呈现在 I-cache 请求端口的旧请求保持到握手，
返回后按 epoch 丢弃；不能中途撤销被反压的 valid。FENCE.I 从提交恢复到维护完成期间
禁止新预测查询，I-cache/BTB/RAS 失效完成后才恢复查询。

## 源码阅读顺序

| 文件 | 文件内部的功能顺序 |
| --- | --- |
| [IFU](../../vsrc/riscv32/core/frontend/riscv32_ifu.sv) | 共享容量反馈 → PC/预测接口与更新 → 请求队列输出/下一值/更新 → 返回配对与交付 → 断言 |
| [预测控制](../../vsrc/riscv32/core/frontend/riscv32_branch_predictor.sv) | 训练入口 → 并行 BHT/BTB/RAS → 预测选择 → 响应保持；两条路径见 [预测器说明](FETCH_PREDICTOR_DESIGN_RECORD.md) |
| [I-cache](../../vsrc/riscv32/core/frontend/riscv32_icache.sv) | 子模块连接 → 查询与替换 → 失效控制及元数据写口 → 性能事件 → 断言 |
| [miss 单元](../../vsrc/riscv32/core/frontend/riscv32_icache_miss_unit.sv)、[AXI 适配器](../../vsrc/riscv32/core/frontend/riscv32_icache_axi.sv) | 状态声明与派生条件 → 组合输出 → 下一状态 → 时序更新 |
| [fetch buffer](../../vsrc/riscv32/core/frontend/riscv32_fetch_buffer.sv) | 队列输出 → 指针/数量下一值 → 数据与控制更新 |

并行电路和控制反馈单独成组，不为了凑成从上到下的直线而增加寄存器。

## 设计取舍与验证

小容量预测表采用组合读取，取消中间查询级和重复状态，代价是单周期组合路径更长。
I-cache 保留同步读；其数据阵列的写入暂存用于保证低电平锁存窗口内地址、数据、使能稳定。
这些状态与反压缓冲有明确用途，不按寄存器数量直接判断是否冗余。

参数入口为 [Makefile](../../Makefile) 的 `rv32-baseline` 配置，经
[riscv_config_pkg](../../vsrc/riscv32/common/riscv_config_pkg.sv) 传入 RTL。
功能、面积、频率和性能数据在[本轮验证记录](../verification/RV32_CYCLE_OPT_2026-09-19.md)
维护；这里不复制结果表或后续架构计划。

空请求队列与空 fetch buffer 支持直通；满队列出队时可同拍入队。taken 响应直接查询目标，
连续命中跳转的查询间隔为一拍。具体状态边界与验证见[本轮优化记录](RV32_CYCLE_OPT_DESIGN.md)。
