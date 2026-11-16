# Replay 取指预测器：原理与电路

当前实现，2026-10-11。旧顺序核接入正式版本选定的预测方案；I-cache 保持
256 B/单路/16 B 行/policy0，D-cache 关闭。配置与测量见
[接入记录](../verification/RV32_REPLAY_HYBRID_2026-10-11.md)。

## 电路和状态

| 模块 | 功能与状态 |
| --- | --- |
| `branch_predictor` | 解析分类、并行查表结果选择、唯一预测响应寄存器与握手 |
| `bht` | BHT16 两位饱和计数器，PC 索引，组合查询、条件分支训练 |
| `btb` | BTB16/两路，完整 tag/目标/类型、有效位与轮转指针 |
| `ras` | RAS4 返回地址栈、写指针与占用数，仅按已解析调用/返回更新 |
| `branch_choice` | 强态使用动态方向，弱态使用 BTFNT，无寄存器 |
| `direct_target` | I-cache 返回后的 B/J 识别、立即数解码、PC 加法与方向选择，无寄存器 |
| `ifu` | 请求/预测配对、方向快照、返回交付和早期恢复，沿用原请求队列及 epoch |

源码顺序：训练分类 → 并行 BHT/BTB/RAS → 混合方向与目标选择 → 单级响应寄存器；
IFU 按 PC 请求 → 两项请求队列 → I-cache 响应配对 → B/J 早期计算 → 恢复与交付组织。
原缓存、后端、前递及寄存边界保留，不引入其他预测实验。

## 查询与早期修正

BHT、BTB、RAS 同拍给出组合结果；BTB miss 先选择 PC+4。
BTB 命中的条件分支：BHT 为 01/10 时使用目标位移的后向 taken、前向 not-taken；
00/11 按最高位。JAL/JALR 预测 taken，返回优先用非空 RAS，否则用 BTB 目标。
不对齐目标禁止 taken。请求握手沿保存 PC、epoch、预测及两位 BHT 计数器，下一拍可消费；
响应反压时保持，消费旧响应的同沿可接收新请求，没有各表自己的寄存级。

I-cache 返回后，`direct_target` 从真实指令取得 B/J 立即数，复用请求时计数器快照。
计算出的下一 PC 与原预测不同且当前指令交付时，IFU 仅清年轻预测，递增 epoch 并重新取指；
当前指令与已进入 fetch buffer 的老指令继续交付，并携带修正后的预测供 EX 校验。
已展示而受阻的 I-cache 请求不能撤销；保留并按原握手排空，其旧 epoch 响应不交付。
外部恢复优先于早期修正。JALR 不在返回后重新计算目标，仍由 BTB/RAS 和 EX 处理。

## 训练、恢复和旁路

训练来源为无异常控制流 EX 结果的交付事件，沿前读旧表、交付沿更新。
BTB 同 tag 优先，再最低编号空路，最后轮转；连续训练下一拍直接观察写入结果。
EX 结果显式携带真实 `branch_taken`，目标恰好为 PC+4 也能正确训练。
训练不加队列或寄存级，不向查询组合旁路 EX 结果。

复位将 BHT 置 01，清 BTB 有效位、轮转指针及 RAS 占用数/指针。
维护失效清 BTB/RAS，BHT 保留；该沿不训练。维护期间暂停新预测查询，旧响应和请求排空。
flush 清预测响应，保持表状态；既有 FENCE.I、异常和总线错误恢复规则保留。

## 开关与验证

默认 `BRANCH_PREDICTOR_ENABLED=1`、`BRANCH_STATIC_POLICY=2`、`BRANCH_EARLY_TARGET=1`。
使能为 0 时，BHT/BTB/RAS 与早期目标均不实例化，元数据恒零，顺序取指并由 EX 恢复；
原 PC/epoch/valid 响应级和握手保留。策略0、早期目标0提供旧纯动态对照。
TAGE/SC/Loop、推测历史、早期 RAS、compact BTB 及其他替换策略没有在本工作区接入。

`python3 npc/scripts/test_replay_predictor.py` 验证独立模型、强弱方向、目标边界、随机恢复和
无预测模式。整核维护/错误回归与原生 MicroBench test 的结果只在上述接入记录维护。
interview 工作区不修改；当前 replay 是旧硬件加正式预测方案，不再是逐字旧 RTL。
