# RV32 最终配置：等待、旁路与状态复查

本轮没有改动 DUT RTL。常见命中和事务交接路径已有直通；仍有可进一步压缩的边界，
不能据此宣称“所有冗余已消除”。本次确认了脏行写回接收后的一拍回填发起等待，
其余候选需要增加冲突处理或延长组合路径。没有取得新方案的周期、面积和时序对照，
因此保留用户选定配置。

## 检查范围

- 基础提交：`e751542b26094a8da2e79fdf5ecdd0fdc3825365`，分支 `branch-v3-20261001`。
- 预设：`rv32-balanced`，RV32I 顺序单发射；I$ 1 KiB/4路/32 B/策略13，D$ 256 B/2路/16 B；
  BHT16、BTB16项/2路、RAS4、弱态BTFNT、早期直接目标，700 MHz。
- 对综合清单的56份输入（5个包、51个模块）按连接逐组检查。清单中的TAGE、TAGE-SC-L、
  compact BTB是关闭的可选实现；历史独立decode/RR级不在当前清单。仿真监视器与历史
  实验不按“未生成硬件”删除。本轮没有重新全面验证延迟模型或所有实验配置。
- 开始时已有 `am-kernels`、`ysyxSoC` 子模块改动及10个未跟踪性能摘要目录，均未改动。
  本轮修改测试和说明；配置、综合输入RTL和计时模型保持不变。

## 已有的直通与保留的状态

以下文件均省略 `riscv32_` 前缀。`frontend/`至`control/`位于`vsrc/riscv32/core/`，
`system/`和`common/`位于`vsrc/riscv32/`。

| 电路范围 | 检查结果 |
| --- | --- |
| `frontend/ifu、fetch_buffer` | 请求队列和取指缓冲空时直通，允许同拍出入；预测taken后可连续发目标查询。epoch、tag及预测快照分别负责失效和响应配对；已展示且受阻的I-cache请求不能被撤回 |
| `branch_predictor、bht、btb、ras、branch_choice、direct_target` | BHT/BTB/RAS并行查询，只有一级响应寄存器；响应消费与新查询接收可同拍。训练直接更新表，无旧三级训练流水。方向混合和直接目标为组合逻辑。关闭的历史预测、替换元数据不应按源码声明估算面积 |
| `icache、icache_tag_array、icache_data_array、icache_replacement` | 同步阵列读后组合比较/响应，无额外S2级，hit吞吐可达每拍一个。策略13的查询快照带同组hit反馈。tag/data读出和请求身份需对齐；锁存数据阵列的回填写入暂存有明确写窗口用途 |
| `icache_miss_unit、icache_axi、pma` | miss分配当拍可发refill，空闲AXI适配器直接发AR，关键字当拍返回，反压才缓存。响应已生成位防止重复响应；剩余burst、累计错误与事务身份必须保留。PMA无状态 |
| `decode/idu、regfile、operand_mux` | 组合译码、异步GPR读取，无独立RR寄存级。最近生产者优先，EX、EX结果、成功LSU完成和WB均有前递；x0不保存。不能绕过较新的未就绪生产者去取较老结果 |
| `execute/id_ex_reg、exu、ex_result_reg` | 弹性接收可同时消费/替换；执行结果级承担结果保持与分支纠错边界。提前保存预测下一PC和少量生产者属性用于缩短路径，不是新增一级。非分支错误taken在EX发射边界纠正，包含访存指令 |
| `memory/lsu、data_mem` | LSU空闲请求直发；成功完成当拍允许下一条接收，load完成可前递；路由保存旧响应归属，允许新事务选择不同目标。局部异常完成保留一拍，避免抢在较老EX结果之前完成 |
| `dcache、dcache_tag_array、dcache_data_array` | 命中直接响应；store hit与下一查询可同拍，同址数据字节及dirty元数据有前递。clean跳过干净路，可衔接下一组读。同步阵列输出有实际使用者，无重复响应级 |
| `dcache_miss_unit、dcache_axi、uncached_axi` | victim同步读取连续推进，最后一字直发写回。读写事务独立跟踪，正常refill不等待B完成；最后必要R/B可直接完成。uncached成功响应与新请求可同拍，错误禁止交接。victim缓冲须保护至写回结果确定，写回失败恢复旧脏行不能删除 |
| `writeback/completion_mux、wb_reg、commit、csr_file、pmu` | 完成选择与commit为组合，只有WB结果寄存边界；LSU完成优先有年龄顺序依据。CSR保存架构状态，PMU低/高半计数保持软件可见64位语义，无CSR读取FSM |
| `control/hazard_ctrl、redirect_mux、trap_ctrl、interrupt_ctrl、fence_i_ctrl` | 冒险和恢复选择无额外流水级；较老EX异常挡住年轻访存。LSU成功返回时解除阻塞，未完成时保持顺序核的年龄关系。中断保存准确恢复PC；FENCE.I排空已展示请求、clean成功后invalidate，失败进入硬件停止状态 |
| `system/axi4_arbiter、axi4_router、peripheral/axi4_clint` | 仲裁/路由允许最后响应与新地址同拍，旧响应归属不能随新地址改变；独立AW/W接收。CLINT响应也可交接，mtime高半快照保证一致读取 |
| `system/axi4_soc_width_converter、reset_controller、core_reset_boundary、npc_system、npc_axi`，`core/core` | RV32等宽通路组合连接，无宽度拆分FSM开销；复位同步和低相位释放不属于指令流水冗余；其余顶层负责装配 |
| `common/`五个包 | 类型、参数、地址和接口定义，不因文件层次而生成额外寄存级 |

当前大部分主体源码按请求/选择、运算或阵列、响应与反馈、状态更新组织；模块拆分没有
自动增加时钟边界。没有找到需要删除的当前实例或能够直接去掉、且不改变时序/协议的
大组重复状态。此结论是源码审查和定向验证的范围性结论，不是全配置形式等价证明。

## 仍值得评估的边界

| 位置 | 当前多等在哪里 | 旁路必须补齐什么 | 本轮决定 |
| --- | --- | --- | --- |
| `dcache_miss_unit`普通脏替换 | 写回请求被接收后，下拍进入`MISS_SEND_REFILL`才发读请求 | 同拍AR/AW的独立握手和反压；写回错误后的victim保护；新增ready到请求路径时序 | 确认存在，优先作为小范围后续实验；不是AXI强制等待 |
| `ifu`恢复入口 | redirect/early_redirect当拍flush并禁止查询，新PC下拍查询 | 恢复目标到BHT/BTB的组合路径、flush与新响应捕获优先级、epoch以及受阻旧I-cache请求 | 影响可能较大，但必须先检查关键路径；不能只删掉`!frontend_restart_event` |
| I/D-cache miss完成到新lookup | 完成当拍仍因miss busy拒绝新查询 | 同沿安装的tag/present/dirty旁路；最后回填字与同步读冲突；I$低电平数据写窗口；异常和失效优先级 | 有条件的可压缩边界，不能只放宽ready |
| `fence_i_ctrl`空排空阶段及阶段交接 | 即使已无旧访问，仍进入DRAIN一拍；clean/invalidate按状态依次发出 | 必须计入提交当拍仍可能接受的旧请求、已展示受阻请求和clean错误；避免清表后保留旧预测 | 低频维护路径，暂不增加组合交接复杂度 |
| 串行指令、中断受理 | 仍将当拍将提交的WB视为占用 | CSR写后读与中断使能可见性、trap/mret优先级、提交恢复PC旁路 | 顺序语义有依据，不能直接取消WB占用判断 |

脏替换的第一项曾在[9月21日记录](RV32_REFINEMENT_2026-09-21.md)中作为H2撤回。
当时存在存储延迟模型对AR/AW次序敏感的问题，且映射策略、频点、前端配置均不同；
**不能拿旧退化数据证明当前device-clock模型下同拍发起不值得做。** 本次没有重新实现
H2或运行其PPA/负载对照，因此也不宣称当前已证明其更优。

## 用现有train结果判断规模

数据来自用户提供的700 MHz、device-clock-v1运行；本轮没有重新跑train。
整程序为642,063,812拍，不能用该范围的事件数直接除以Total或Scored窗口。
Total为641,446,522拍、0.916352 s、IPC 0.416145342；Scored为517,971,161拍、
0.739959 s、IPC 0.360657776。

| 整程序观察值 | 数量/比例 | 能说明什么 |
| --- | ---: | --- |
| LSU structural stalls | 276,388,764拍 / 43.047% | 数据侧等待占比大，但包含真正的存储服务时间，不等于可删除的控制气泡 |
| control recovery stalls | 52,366,168拍 / 8.156% | 恢复时机值得检查；不能假定这些周期都能靠一条旁路消除 |
| 脏victim miss | 704,017次 | 每次局部少一拍的事件规模约为整程序0.110% |
| I$完成时已有下一请求 | 272,980次 | 每次局部少一拍的事件规模约0.043%；其中259,435次同组，不能忽略安装冲突 |
| D$完成时已有下一请求 | 409,519次 | 每次局部少一拍的事件规模约0.064%；同组168,086次、异组241,433次 |

后三项只是固定轨迹下的局部一拍机会估算，不是实测加速，也不是重新调度后的严格上限；
不能相加宣称收益。等待分类亦可能重叠，不把各类比例相加。相比之下，只删除极少触发的
维护交接很难明显改变这次train用时。当前顺序核在LSU未完成时限制年轻执行有精确异常
和完成顺序依据；放开独立执行属于新的并发完成设计，不能当作删一个无用stall处理。

## 验证与本轮修改

11个目标通过：`test-fetch`、`test-icache`、`test-lsu`、`test-pipeline`、`test-dcache`、
`test-dcache-miss`、`test-dcache-axi`、`test-uncached`、`test-axi-handoff`、`test-fence-i`、
`test-precise-exception`。流水线测试另覆盖static policy 0/1/2（均使用bimodal方向表）。

- 取指taken循环目标间隔1拍；取指队列检查1012次输出、746次同时出入、34次flush。
- D-cache miss契约102例：`capture_waits=0`、`refill_waits=36`，直接区分已实现的最后
  victim字直通与尚存的写回/回填交接等待；另有8例AXI、24例uncached交接、10例总线交接。
- 整核cache恢复84例，精确异常40例通过。
- 首次pipeline测试失败于过时的弱态预测断言：前向分支的counter从01训练到10，纯动态
  应taken，弱态BTFNT应not-taken。修改按配置表达预期，并增加前/后向×四种counter状态，
  三种模式共24种组合；保留原动态检查，没有关闭断言。删除测试中遗留的多拍训练等待和
  旧三级训练流水注释。初次失败日志保留。
- 更新微架构目录的默认启用描述，以及I-cache说明中旧720 MHz预设文字。没有新增规范文档；
  现有[寄存器、等待与旁路检查](../development/NAMING_GUIDE.md#寄存器等待与旁路检查)已覆盖本轮要求。

复现使用`make -C npc git_commit= NPC_CONFIG=rv32-balanced BUILD_DIR=... <目标>`；
各测试的准确命令、工具版本、源码哈希和原始日志在
[机器记录](data/wait-review-20261002/summary.json)及其`logs/`目录。
本轮未重新运行综合/STA、MicroBench或整套DiffTest，不新增面积、频率或性能结论；
此前102,253.060 μm²/700 MHz仍是冻结候选的历史测量。编译产物按规则清理，保留小型证据。
