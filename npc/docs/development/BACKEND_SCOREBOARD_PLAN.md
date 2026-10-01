# 多功能单元与顺序提交：设计前依据

2026-09-28。本文保留实施前的依据与验收条件。实验后端已按此方向实现，当前电路以[多功能单元后端说明](../microarchitecture/BACKEND_DESIGN.md)为准。初版 WAW 等待已通过 ROB 结果版本与最近生产者选择消除；下文的保守 WAW 规则属于历史方案。稳定默认配置仍使用原后端。

## 当前结构与目标

当前单发射核可重叠执行独立乘法，但普通结果仍沿固定流水顺序交付。hazard 在 LSU 未成功完成时阻塞执行，EXU 也要求乘法流水排空后才允许年轻访存进入 LSU。除法依赖 ID/EX 持续保存操作和操作数。多个 FU 不等于已经支持任意结果乱序返回。

`riscv32_commit` 已生成 GPR 写入及 CSR/异常提交事件，并非闲置模块。它只接收一条已排序的 WB 结果，没有在途队列，输入 ready 恒为真。`riscv32_completion_mux` 的 LSU 优先策略依赖现有暂停规则；源码已明确要求未来放开重叠时增加年龄管理。store 的实际访存发生在到达 commit 之前，安全性由老指令阻塞条件保证。

目标是：**每拍至多顺序发射一条，允许不同 FU 乱序完成，每拍至多按序提交一条。** 暂不做寄存器重命名，不允许年轻指令越过尚未发射的阻塞指令；仍有发射队首阻塞，不能称为完整乱序发射核。

## 参考实现

| 一手资料 | 已核对的职责 | 采用边界 |
| --- | --- | --- |
| [CVA6 issue 文档](https://docs.openhwgroup.org/projects/cva6-user-manual/03_cva6_design/issue_stage.html)、[scoreboard RTL](https://github.com/openhwgroup/cva6/blob/master/core/scoreboard.sv) | transaction ID 配对返回结果，维护发射和提交位置 | 此 scoreboard 包含退休队列职责，不能理解成只有 busy 位 |
| [CVA6 操作数发射 RTL](https://github.com/openhwgroup/cva6/blob/master/core/issue_read_operands.sv) | 依赖、FU 接收能力及前递 | 请求必须连同操作数和身份一起被接收 |
| [CVA6 commit 文档](https://docs.openhwgroup.org/projects/cva6-user-manual/03_cva6_design/commit_stage.html)、[commit RTL](https://github.com/openhwgroup/cva6/blob/81245a47fad8fe1a5d562d953ef2662e099def76/core/commit_stage.sv) | 队首退休、GPR/CSR 更新和 LSU 提交授权 | 扩展现有 commit 的等待和授权协议 |
| [CVA6 store buffer RTL](https://github.com/openhwgroup/cva6/blob/master/core/store_buffer.sv) | 区分未提交和已提交 store | 顺序写寄存器不能补救提前发出的错误路径 store/MMIO |
| [BOOM ROB 文档](https://docs.boom-core.org/en/latest/sections/reorder-buffer.html)、[ROB RTL](https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/exu/rob.scala)、[rename 文档](https://docs.boom-core.org/en/latest/sections/rename-stage.html) | ROB 管理年龄、完成和异常；重命名、物理寄存器另有职责 | 保留模块接口，不把未来所有调度与结果数据都塞进 ROB |

本日读取上述官方资料。CVA6 官方 master 查询到 `81245a47fad8fe1a5d562d953ef2662e099def76`，commit_stage 已核对固定版本；其他 master 网页可能随更新变化。历史文档和当前多配置源码不能不加区分地当作同一硬件。这里只采用职责划分，不照搬容量、端口数、MMU、浮点或超标量实现，也未复制第三方 RTL。

## 建议模块边界

| 模块 | 职责和状态所有权 |
| --- | --- |
| `riscv32_scoreboard` | 源操作数、目的寄存器冲突、FU 可接收判断及前递选择；不重复保存完整退休队列 |
| `riscv32_rob` | 顺序分配槽位，按身份接收结果，保存完成/异常和提交元数据，只向 commit 展示队首 |
| `riscv32_commit` | 判定队首能否退休，更新 GPR/CSR，生成异常与恢复，并授权有副作用的访存 |
| 各 FU 与 LSU | 接收后保存必要操作数和身份；结果受阻时保持；恢复时取消或排空未提交事务 |

建议把 ROB 独立成模块。scoreboard 与 ROB 共用指令身份，而不是在 CVA6 式完整 scoreboard 外再复制一套在途队列。先以 4 项作实验起点，比较 2/4/8 项，容量还没有 PPA 结论。小容量先评估从 ROB 条目组合生成依赖信息，不无依据地复制 32 项 busy/tag 状态；若形成关键路径，再比较独立依赖表。

第一版不重命名：同一非零目的寄存器的老写者退休前阻塞年轻写者，保守处理 WAW。RAW 可从已完成条目或当拍有效完成结果前递，异常结果不能前递。所有源操作数在 FU 接收时取齐并锁定，避免延后读取引入 WAR。

初版 ROB 可保存结果供前递与提交。未来采用 PRF 后，结果可转存物理寄存器，ROB 保留目的编号、旧映射和恢复信息；重命名、唤醒选择、访存排序仍有独立职责。

## 必须一起改的接口

1. 发射与完成分开：请求/结果携带身份，除法不再依赖 ID/EX 长期保持。槽位分配和 FU 接收要原子完成，或明确尚未发射条目的状态。
2. 同拍完成：ALU、乘法、除法、LSU 可能同时返回。未被仲裁接受的结果必须保持；队首不能被年轻结果永久饿死。不能只接到原先假定有序的 completion mux。
3. 完成与退休分开：完成只更新 ROB，GPR/CSR 在退休边界更新。commit 增加真实 ready/ack，组合读取 ROB 队首；不因拆模块强制增加搬运拍。完成到提交的旁路须覆盖异常与同拍冲突后才能采用。
4. 恢复按年龄处理：分支误预测和非分支错误 taken 都保留更老条目、取消年轻项；异常到队首再报告。定义 flush 与完成同拍、指针绕回和取消后旧响应的优先级。旧响应排空或确认取消前不复用相同身份；采用代际位必须证明绕回边界。
5. 中断在明确的退休边界受理。CSR/mret/FENCE/FENCE.I 初版保持串行化，不回退 FENCE.I 恢复、clean 失败停止和 dirty-victim 保护机制。

## 访存分两步开放

先验证多个算术 FU 乱序完成，保留访存限制。这一步不能被宣传成已经解决 `fib` 的乘法后 load 等待。

随后允许普通可缓存 load 与老算术指令重叠，但仍只保留一个在途数据访存，不越过老 store，不做地址猜测、重放或多 miss。数据或访问异常写回对应 ROB 项；错误路径响应可丢弃，已经握手的总线事务仍须排空。仅 PMA 明确允许投机的普通内存适用；MMIO 和属性不明的 uncached 读也可能有副作用，应等队首再发出。

store 初版仅在队首且没有更老异常/恢复时授权发出，等当前存储协议要求的完成或错误再释放该项。**授权开始 store 不等于已退休。** 后续如引入已提交 store buffer，必须另行规定延迟总线错误策略，不能先退休再补属于该 store 的普通精确异常。

当前 LSU 没有完整投机取消协议；开放重叠不能只删除 EXU 的 `!pipeline_busy_o`。需要一起修改身份、返回接收、错误处理及提交顺序。

## 验证与取舍

- 正确性：长除法后独立 ALU/乘法先完成但按序退休；RAW/WAW；同拍完成与反压；满队列同拍出入；老异常加年轻 store/MMIO；误预测和非分支错误 taken；恢复同拍响应及身份绕回；访问错误、中断、FENCE.I。在原断言、参考结果和回归上增加覆盖。
- 观察器：统计 FU 接收间隔、ROB 占用、队首等待、RAW/WAW 等待与 LSU 等待，确认重叠真实发生。不在工作负载插入 CSR 读取。
- 对照：冻结当前 700 MHz 阻塞版和流水版，用同镜像、同延迟模型跑 MicroBench test/train、独立/相关算术混合和量化内核。先测算术重叠，再单独开放 load，避免混算收益。
- 取舍：报告周期、合法频点时间、面积和总线流量，以面积乘执行时间及单项退化作判断。scoreboard/ROB 名称不构成默认启用理由，也不为未来功能增加当前无用途的状态。

当前 train 的静态检查：`fib` 的 `mul` 后紧接 `lw`，旧新版普通非零 MUL 均为三拍；两次运行前八项显示时间及共有 19 个计时采样点的周期/退休数一致。这只是检查时完成的前缀，不是完整 train 最终结果，也不是动态乘法占比。对应运行为 `passive-train-20260928T074154Z` 和 `passive-train-20260928T123834Z`，软件镜像一致。
