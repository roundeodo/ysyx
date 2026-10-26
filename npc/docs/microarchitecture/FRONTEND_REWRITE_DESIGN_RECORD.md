# RV32 前端：数据流与源码顺序

当前实现，2026-10-25。阅读入口；预测器和 I-cache 的内部细节分别在各自说明中维护。

## 取指怎样完成

1. **并行查询**：IFU 将同一 PC、epoch 同拍送往预测器与 I-cache。预测器并行读取
   BHT/BTB/RAS；cache 同步读取 tag/data。二者之间没有串联的查询寄存级。
2. **响应配对**：预测器的响应寄存器保存当前取指的预测。命中时两路同时可用；miss 或
   译码反压时，预测保持到对应指令交付，不复制到 IFU 的另一份在途寄存器。
3. **返回与早期纠错**：IFU 丢弃旧 epoch 响应；直接目标单元识别 JAL/条件分支，
   按指令立即数计算目标，结合方向策略比较下一 PC，必要时提前重定向。
   可选早期 RAS 默认关闭。见[分支探索电路说明](BRANCH_V3_DESIGN.md)。
4. **连续发出与保持**：当前响应交付的同沿可以启动下一对查询，命中吞吐一拍一条。
   cache 暂不接收时只保存一个已展示请求，其预测已进入预测器；该请求不重复查询，
   即使恢复或维护到来也保持到 cache 握手。没有额外的预取请求队列。
5. **交付与译码**：有效指令通过两项 fetch buffer，空时直通，译码反压时保存。

预测训练是独立的反馈路径：从无异常 EX 结果的交付事件直接更新 BHT、BTB、RAS，不再经过训练寄存器。
上面的条目表示功能顺序，不表示固定流水级；实际周期边界由下表中的寄存器决定。

## 状态与保留理由

| 位置 | 保存内容 | 存在理由 |
| --- | --- | --- |
| IFU PC / epoch / tag | 下一查询地址、重定向代次、请求编号 | 连续发出请求，并识别过期响应 |
| 预测器响应寄存器 | PC、epoch、完整预测 | 与 cache S1 并行采样；保持至对应指令交付 |
| IFU 请求保持 | 一个已展示、尚未被 cache 接收的地址、epoch、tag | 首次受阻才保存；满足请求稳定性，不保存重复预测 |
| I-cache | 同步阵列输出、对齐请求、miss 上下文、响应和失效状态 | 见 [I-cache 说明](ICACHE_DESIGN_RECORD.md) |
| fetch buffer | 两项指令及读写指针、数量 | 吸收译码反压；没有额外的指令搬移级 |

redirect 更新 epoch 并清除年轻预测。已经呈现在 I-cache 请求端口的旧请求保持到握手，
返回后按 epoch 丢弃；不能中途撤销被反压的 valid。FENCE.I 从提交恢复到维护完成期间
禁止新预测查询，I-cache/BTB/RAS 失效完成后才恢复查询。

## 源码阅读顺序

| 文件 | 文件内部的功能顺序 |
| --- | --- |
| [IFU](../../vsrc/riscv32/core/frontend/riscv32_ifu.sv) | 返回配对与预测保持 → 并行请求/PC与受阻请求保持 → 返回指令识别、可选 RAS 保持、直接目标计算、下一 PC 比较、响应组装 → 断言 |
| [预测控制](../../vsrc/riscv32/core/frontend/riscv32_branch_predictor.sv) | 训练入口 → 并行 BHT/BTB/RAS → 预测选择 → 响应保持；两条路径见 [预测器说明](FETCH_PREDICTOR_DESIGN_RECORD.md) |
| [I-cache](../../vsrc/riscv32/core/frontend/riscv32_icache.sv) | 子模块连接 → 查询与替换 → 失效控制及元数据写口 → 性能事件 → 断言 |
| [miss 单元](../../vsrc/riscv32/core/frontend/riscv32_icache_miss_unit.sv)、[AXI 适配器](../../vsrc/riscv32/core/frontend/riscv32_icache_axi.sv) | 状态声明与派生条件 → 组合输出 → 下一状态 → 时序更新 |
| [fetch buffer](../../vsrc/riscv32/core/frontend/riscv32_fetch_buffer.sv) | 队列输出 → 指针/数量下一值 → 数据与控制更新 |

并行电路和控制反馈单独成组，不为了凑成从上到下的直线而增加寄存器。

## 设计取舍与验证

小容量预测表采用组合读取，取消中间查询级和重复状态，代价是单周期组合路径更长。
I-cache 保留同步读；其数据阵列的写入暂存用于保证低电平锁存窗口内地址、数据、使能稳定。
这些状态与反压缓冲有明确用途，不按寄存器数量直接判断是否冗余。

当前选定参数入口为 [Makefile](../../Makefile) 的 `rv32-balanced` 配置，经
[riscv_config_pkg](../../vsrc/riscv32/common/riscv_config_pkg.sv) 传入 RTL。
功能、面积、频率和性能数据在[本轮验证记录](../verification/RV32_CYCLE_OPT_2026-09-19.md)
维护；这里不复制结果表或后续架构计划。

并行查询删除了预测响应之后才启动cache的固定等待；同步预测与cache读口仍各自保留。
连续命中 taken 的查询间隔为一拍，redirect后首个请求无需等待预测返回再发cache。
验证、同条件周期与STA见[并行查询记录](../verification/RV32_PARALLEL_FETCH_2026-10-25.md)。
