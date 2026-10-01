# 多功能单元后端

可选配置支持**单发射、顺序发射、乱序完成、顺序退休**。默认仍使用原后端。
没有 PRF、重命名表或乱序发射队列；年轻指令不能越过尚未发射的阻塞指令。
LSU 默认单事务，可选两项上下文与 D-cache hit-under-miss，见[并发访存设计](LSU_CONCURRENCY_DESIGN.md)。

## 流水边界

取指 → fetch buffer 空时直通 → Decode → **Issue** → Execute → FU 完成 → ROB 队首选择与 Commit。
不同 FU 延迟不同，不能把这个弹性结构说成所有指令都固定经过相同的六拍。

| 位置 | 保存与处理什么 |
| --- | --- |
| Decode | 组合解释指令字段、立即数、操作与异常；输出写入 `riscv32_issue_reg` |
| Issue | 保存一条译码指令；读取 GPR/CSR，scoreboard 选择最近老写者及前递；等待源值、执行入口和 ROB 容量 |
| Execute 入口 | 复用 `riscv32_id_ex_reg` 保存已选定操作数，与 ROB 分配同拍成功；FU 接收后可交接下一条 |
| FU | ALU/分支结果、流水 MUL、迭代 DIV、可配置 LSU 各自计算和返回身份 |
| ROB / Commit | 保存未退休结果；ALU 结果级与 MUL 的队首完成可当拍送 Commit，其余读取已完成项，按序更新 GPR/CSR 或报告异常 |

Issue 是明确的寄存边界，空时不旁路，但支持旧项发射与新项接收同拍，吞吐上限一条/拍。
fetch buffer 只吸收反压，恢复空时直通。没有用强制 FIFO 落拍代替 Issue，也没有另加 WB 搬运寄存器。
Issue 尚未发射的指令没有 ROB 身份；GPR 地址、CSR 地址和控制都属于同一条 Issue 指令。
具体握手与恢复见 [Issue 说明](ISSUE_DESIGN.md)。

## 前递与 FU 并行

- scoreboard 是组合年龄查询，没有额外 busy 表或流水寄存器。不同 ROB 项保存同一架构寄存器的不同版本，不增加 WAW 等待。
- 保留当前 Execute ALU、FU 当拍完成、已完成 ROB 项到 Issue 的前递；最近老写者未完成时不能选更老的值。
- ALU 结果级、流水 MUL 的队首完成可直接退休；未到队首或 Commit 反压时写入已有 ROB 项，不新增缓冲。DIV 和 LSU 先写 ROB，避免完成→退休/恢复→派发的组合反馈。完成到 Issue 的前递不经过 Commit。
- 满 ROB 可同拍退休和分配；Issue、执行入口均支持同拍交接。MUL 每拍可接收一条独立乘法。
- DIV 迭代上下文由除法单元及后端保存，不占住执行入口；其运行期间可以派发独立 ALU、MUL 和允许提前执行的 load。
- 默认 LSU 只有一个在途事务，后续访存可能阻塞顺序派发。两项配置允许再接收一条请求；是否立即访问缓存取决于端口和预留行，不代表两个 miss 能同时回填。第二条除法仍不能越过忙碌 DIV。

这使独立操作能够重叠，但不会自动加速存在 RAW 链、访存瓶颈或频繁分支恢复的程序。
与 CVA6 多在途 LSU、不同 D-cache 配置的差距见[LSU 研究记录](../learning/CVA6_LSU_REVIEW.md)；当前已实现的子集及测量见[并发访存记录](../verification/RV32_LSU_CONCURRENCY_2026-10-01.md)。
原后端已支持连续流水乘法，不能将这项能力或收益全部归因于 ROB。

## 精确状态与恢复

分支在 ALU 结果级检查预测，ROB 按年龄保留分支及老指令、取消年轻项。
非分支错误 taken 在顺序派发边界纠正，覆盖整数、乘除法和 LSU；当拍禁止年轻分配。
异常只在队首报告；前端恢复清除尚未发射的 Issue 指令。

store、MMIO 和 uncached 读必须获得队首授权；老队首正常退休时可授权下一项。
普通 load 提前执行仅限 PMA 明确允许的 readable/cacheable/idempotent 区域，不越过老 store。
已握手的错误路径 load 排空后丢弃响应；对应 LSU 槽位在响应前不复用。双项配置的其他空槽仍可接收安全 load，各自保存 ROB 身份和取消标志。

CSR、FENCE、FENCE.I、mret 串行化，并等待撤销的 LSU 请求排空。
中断阻止 Issue 发射并排空已分配的后端；未发射 Issue 项可在恢复时取消，不计入必须排空的 busy。
FENCE.I 的 clean 失败停止和 dirty-victim 恢复保留原协议。

## 配置与证据

使用 `rv32im-pipelined`，显式设置 `NPC_BACKEND_ROB_ENABLE=1`、`NPC_BACKEND_ENTRIES=4`、
`NPC_BACKEND_LOAD_OVERLAP=1`；性能脚本对应 `--backend-rob 1 --backend-entries 4 --load-overlap 1`。
默认不开启。原生计时与退休统计继续由仿真器被动观察，没有给程序增加 CSR 采样指令。

`NPC ROB:`、`NPC FU:` 是纯仿真计数，覆盖整次仿真，不能直接当作 Total/Scored 窗口计数。
`test_backend_input.py` 检查 Issue/FIFO/scoreboard；`test_backend_rob.py` 检查完成、前递、退休和槽复用；
`test_backend_recovery.py` 检查恢复；`test_backend_core.py --require-overlap` 检查真实 FU 重叠及软件结果。
最新面积、频率、性能与失败尝试统一见 [退休旁路与作用验证记录](../verification/RV32_RETIRE_BYPASS_2026-10-01.md)。
