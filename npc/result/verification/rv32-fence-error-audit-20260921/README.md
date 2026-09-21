# FENCE.I 与写回错误核查：2026-09-21

源码：开发提交 `7dfa2d6`，对应发布提交 `9e64976`，已核对 `npc/vsrc`、测试与脚本相同。
本轮只增加本目录的诊断材料，没有修改产品 RTL。探针退出 0 表示完成观察，**不表示 CPU 正确性通过**。

## 1. 旧 taken 预测穿过 FENCE.I：全核复现

真实 CPU、预测器、I/D-cache 和 AXI adapter，外接统一 RAM 与 MMIO 测试模型。
RV32 baseline：I-cache 256 B / 1 way / 16 B，D-cache 256 B / 2 ways / 16 B；BHT 16、BTB 16 / 2 ways、RAS 4。
软件先执行 A 的 JAL，正常训练 BTB；再用 store 修改 A，通过 D-cache clean 写回，执行 A-4 的 FENCE.I。
无 force 或内部预测状态注入，开启 RTL 断言。

A=0x80000080，T=0x80000100；正确后继 A+4=0x80000084。

| A 的新指令 | A 后实际提交 PC | 错误路径 MMIO store 数 | 结果 |
| --- | --- | ---: | --- |
| nop | 0x80000100 | 1 | 复现错误 |
| lw t1,0(s3) | 0x80000100 | 1 | 复现错误，覆盖 LSU 路径 |
| sw s0,0(s3) | 0x80000100 | 1 | 复现错误，覆盖 LSU 路径 |
| jal x0,A+4 | 0x80000084 | 0 | 分支纠错对照正常，正确路径 MMIO store=1 |

NOP 案例：cycle 72 FENCE.I 提交；73 维护中查询 A；93 写回 B 成功；102 invalidate；
105 返回 A 的新 NOP，但仍携带 taken→T；108 A 提交、next_pc=A+4；114 实际提交 T；120 错误目标发出 MMIO 写。
证据：[汇总](run.log)、[NOP 日志](nop.log)、[load](load.log)、[store](store.log)、[分支对照](jal.log)。
首次分支对照的测试程序在成功标记之后落入 .org 零填充，额外触发非法指令；已补终止跳转并重跑全部四例。
原诊断保存在 `jal-initial-harness-gap.log`，该问题属于探针程序，不计为 RTL 缺陷。

## 2. clean 错误只由断言阻止仿真

同一全核程序，RAM 对代码行写回返回 SLVERR，并不保存该写回的数据。
开启断言时在 core 的 clean-fault 断言退出；同一仿真器加 `+verilator+noassert`，只关闭断言诊断、不改变 RTL 连线：
cycle 93 B=SLVERR；94 进入 invalidate；97 取回旧 JAL；后续继续提交执行。
这验证了当前 RTL 不会因 clean 错误进入硬件 fatal 状态。第二次运行不能称为“断言回归通过”。
证据：[断言日志](clean-error-assertions.log)、[关闭诊断后的日志](clean-error-hardware.log)、[命令](clean-error-runs.json)。

## 3. dirty victim 写回失败后不可恢复：D-cache 级复现

真实 D-cache 与 AXI adapter，模型失败时不修改下层 RAM；该场景是错误响应的一种合法情况，
并不假定所有 AXI 错误都会撤销已完成写入。此前 store 成功响应，A 的缓存值为 deadbeef，下层仍为 0。
访问相同 set 的 B、C 触发 A 的脏替换；写回返回 SLVERR，当前 C 访问得到 access_fault。
随后再次读 A：返回 0 且 access_fault=0。无错误对照相同流程返回 deadbeef。
这项是缓存接口测试，没有模拟完整 CPU trap handler；它证明成功确认的旧 store 数据失去可访问保护。
证据：[失败注入](dirty-fault-1.log)、[无错对照](dirty-fault-0.log)。

## 重跑

从本目录执行：

```sh
python3 run_probe.py
python3 run_clean_probe.py
python3 run_dirty_probe.py
```

构建命令、参数与源码哈希见 `manifest.json`、`dirty-manifest.json`。
修复仍待实施：前端维护与预测快照一致性；覆盖所有指令的错误 taken 纠正；写回失败后的系统策略及硬件处理。
既有测试只验证 invalidate 后重新查询、当前事务错误返回及不安装错误新行，没有覆盖这里的完整观察边界。
