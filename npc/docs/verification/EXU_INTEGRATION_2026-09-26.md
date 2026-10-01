# RV64 执行单元接入与验证

日期：2026-09-26。默认配置：RV64 单发射顺序核，I-cache 1024 B / 4 路 / 32 B / policy 13，
D-cache 256 B / 2 路 / 16 B，BHT 16、BTB 16 项 / 2 路、RAS 4 项。

> 后续复核：本文记录加入 scoreboard 前的实现。当前并发后端见
> [顺序发射与乱序完成验证](SCOREBOARD_INTEGRATION_2026-09-26.md)。旧 STA 日志存在
> 门控后寄存器缺少捕获时钟的诊断，旧验收脚本未拒绝它；下文历史“700 MHz 通过”
> 不构成完整时序证明。原功能、周期和面积记录保留，频率结论另行复核。

## 实现范围

EXU 连接独立组合 ALU、组合分支单元、三级乘法器和迭代除法器，支持全部 13 条 RV64M 指令。
译码、共享类型、misa.M、请求控制、结果前递和恢复取消一起接入整核。当前整核一次执行
一条乘除；单元可连续接收请求，不代表整核已经支持并行发射。

目录按取指、译码、执行、访存、写回和控制分层。30 项文件迁移保留来源，历史流水级
保存在 experiments/pipeline。19 个模块采用与 RV32 对应职责一致的短名；源码、构建入口、
测试和当前文档同步更新，未删除教学、实验或历史材料。

设计取舍见[执行单元设计](../microarchitecture/EXECUTION_UNITS_DESIGN_RECORD.md)，
位置见[模块总览](../architecture/RTL_MODULE_MAP.md)，与 RV32 的区别见
[当前实现对照](../architecture/RV64_RV32_CURRENT_COMPARISON.md)。

## 等待、前递与控制路径

- 普通整数和分支保持原交付周期。乘除结果可用的同拍前递，不额外等写回。
- 三级乘法器由公共 EX 结果寄存级接收最终进位修正和格式化结果，删去重复的内部输出寄存级。
- 除法器对除零、零被除数、除数绝对值为 1、被除数较小和可跳过的前导零提前推进。
- result_present 表示寄存的结果槽状态，result_valid 另检查取消；RAW 就绪判断不依赖 flush 组合路径。
- 非分支错误预测一旦确定即可纠正，历史位防止重复；ID/EX 保留尚未交付的当前项，较老恢复优先。
- 冒险控制先比较寄存器编号，再以 uses_rs 限定；ready 不由 decoded valid 门控，实际前递与交付仍检查 valid。
- I/D-cache 用已有事务占用状态选择响应载荷；D-cache miss 单元提前准备载荷和错误信息。
  响应有效性、关键字提前返回、最终响应与新请求同拍交接均保持原规则。
- IFU 删除已经确定 taken 条件下的冗余选择，保留普通 PC+4，不增加寄存器。

没有新增多周期时序例外。乘法相邻级、最终前递以及每拍更新的除法反馈按单周期检查。

## 功能与等价验证

| 检查 | 结果与范围 |
| --- | --- |
| ALU | 12,816 组独立算术参考检查；另证明全部操作编码与两组 64 位输入相对旧实现等价 |
| 分支 | 7,168 组条件、目标、顺序地址和对齐检查 |
| 独立乘法器 | 4,005 次接收，3,992 次交付，13 次取消；覆盖连续请求和反压 |
| 独立除法器 | 6,408 次接收，6,403 次交付，5 次取消；覆盖结果交付与新请求同拍 |
| IDU + EXU | 10,413 组 RV64M 运算，覆盖阻塞、反压、取消与复位 |
| ID/EX + EXU 恢复 | ADD/MUL/DIV 保持、只纠错一次、年轻输入取消与较老恢复 |
| 整核 DiffTest | 原有 35 个程序和一个含 5,421 组 RV64M 用例的程序，全部通过 |
| 精确异常 | 40 个整核场景全部通过 |
| 缓存恢复 | 84 个整核场景、75 个独立 D-cache 故障场景通过 |
| 前端与冒险接口 | 取指、预测、I-cache、冒险控制四组接口回归通过，含 decoded valid=0 与 LSU 同拍完成 |
| IFU 等价 | 863 个顺序等价点全部证明；输入无约束 |
| D-cache miss 等价 | 1401 个等价点全部证明；仅屏蔽 valid=0 时的响应载荷，状态、握手和副作用均比较 |
| 冒险等价 | ready 解耦检查在 valid=1 时比较 ready；随后 uses_rs 因式分解对全部输出、全部输入组合证明等价 |
| 原有流水形式检查 | 20 拍有界检查通过，使用该入口的 I-cache 1024 B / 2 路 / 8 B / policy 0；不是默认配置整核无限深度证明 |
| 目录整理回归 | 18 组原有 RTL 测试通过；动态拼接旧路径的独立缓存脚本已经修复 |
| lint | 独立核及 SoC 入口通过；仍有既有警告及 IFU 响应 PC 高位未使用警告，不是零警告 |

最终执行单元测试运行 318,375 拍。边界包含除零、有符号溢出、余数符号、MULHSU 和
DIVUW/REMUW 的符号扩展。整核使用已有 NEMU RV64 解释器；原有 35 个程序保留相同二进制。

最终硬件与 library-mapping 功能组合的 71 个 RTL/构建文件完全相同，见
selected-source-bridge.json。整核结果保存于 core-regression-library-mapping、
precise-exception-library-mapping、cache-recovery-library-mapping；执行单元及实际 ID/EX
测试见 unit-tests-redirect-fix，单位源码连续核对见 response-payload-execution-source-bridge.json。
前端接口见 frontend-contracts-library-mapping，独立缓存见 cache-contracts-response-payload。
形式证据分别见 alu-equivalence、ifu-target-equivalence、dcache-response-equivalence、
decode-ready-equivalence 和 parallel-pc-hazard-equivalence。最终应用只再调整已核对等价的空白。

逐文件核对覆盖 vsrc/riscv 的 71 个文件：4 个新增执行单元，10 个功能/接口改动，
54 个只做约定重命名或排版的 HDL，3 个构建清单/说明文件。对照修改前快照并排除约定
模块名替换后，54 个 HDL 的代码标记一致。应用前后哈希、空白等价、配置、命令和日志见
[本轮证据](../../result/verification/exu-functional-units-20260926)。

## 周期测量

| 同一程序 | 四级乘法版本 | 当前三级版本 |
| --- | ---: | ---: |
| 原有 35 个 RV64I 程序 | 基准 | 各程序周期不变 |
| 5,421 组 RV64M 测试程序 | 168,774 | 166,688 |
| 1024 条连续相关 MUL 专项 | 7,226 | 6,203 |

上述为 active core cycles。同镜像、同缓存和平台延迟下测量；专项约减少 14.2% 程序周期，
不能据此声称 AI 应用有相同加速，也不能声称该乘法器面积或级数最优。

## 综合方法与时序

NPC 自有 scripts/synth_timing.tcl 复用既有工具与 PDK 配置，保留原工具脚本的 Apache 2.0
许可头，共享工具目录未修改。实际 Liberty 映射前保留算术门结构；乘法器、除法器独立
映射后再展平，脚本断言二者各存在一个，避免 Slang 专门化模块名导致层次选择失效。

ABC map/upsize/dnsize 都显式收到目标延迟，不重定时。映射代理负载 10 fF；映射目标
默认 820 MHz，完整验收仍是 700 MHz，两者含义不同。小型寄存加法器检查确认 800 MHz
输入在实际三个优化命令中均形成 1250 ps，但这个检查本身不证明整核时序通过。

原共享 AREA3 自定义 ABC 命令未使用 {D}；仅传外层 abc -D 不能证明内部优化使用了目标。
这不否定过去已经完成的 STA，只说明映射参数需要单独核对。手写 PC 进位及其他映射
候选没有带来合格结果，实验均保留，没有据此改变正式 PC 运算或放宽时序约束。

采用版本在 700 MHz 完整验收下通过：

| 项目 | 结果 |
| --- | ---: |
| 数据 setup 最差裕量 | +0.020 ns |
| 门控 setup 最差裕量 | +0.010 ns |
| 数据 hold 最差裕量 | +0.060 ns |
| 门控 hold 最差裕量 | +0.095 ns |
| 违例数 / setup TNS / hold TNS | 0 / 0 / 0 |
| 复位与连接、电容、转换时间检查 | 全部通过 |
| 修复后标准单元面积 | 169,947.134 µm² |

剩余违例来自 AXI 完成到下一请求、EXU/除法器启动使能等控制路径。综合后仅将这些
路径上的 12 个组合单元换为同逻辑、更强驱动的型号；引脚函数、连接、参数、所有
其他单元均逐项核对。面积从 169,938.888 增加到 169,947.134 µm²，仅增加 8.246 µm²。
不增加流水寄存器或等待，不添加多周期/假路径例外，不额外限制全网扇出。

原始独立映射面积中，乘法器为 44,553.936 µm²，除法器为 3,537.534 µm²，其余核逻辑
为 121,048.354 µm²；合计 169,139.824 µm²。该分解在驱动调整和负载修复之前统计，
不能把它的分项直接当作最终物理面积。乘法器并行部分积是新增面积的主要来源。

正式入口由 qualify_mapped_sta.py 调用既有完整验收。只有 setup 失败而 hold、复位与
电气检查均通过时，才允许最多两轮、每轮最多 12 个组合单元的驱动调整；每轮重新
检查全部项目，保留原始与失败报告。不能通过时返回非零，不把工具运行结束当作通过。

已通过结果见 critical-drive-preserved/qualified/acceptance.json。可移植脚本重放选中了
完全相同的 12 项修改，见 critical-drive-helper-replay.json；新入口使用同一已调整网表
实跑并再次完整通过，见 qualification-driver-actual。自动重试及失败传播另有定向测试，
不将这些脚本测试说成布局布线验收。

对照保留了两个未采用结果：独立映射但未调整驱动时数据/门控 setup 为 −0.048/−0.133 ns；
额外简化 result_ready 的候选为 −0.071/−0.004 ns。后一候选功能正确、周期不变，但整核
时序未通过，因此本轮未合入。失败报告和源码均保留在证据目录。


2026-09-25 的 124,259.772 µm² / 700 MHz 属于加入 M 扩展前的核，不能用作本轮结果。
所有面积/时序仅限 Nangate45 typical、理想时钟和记录的输入输出预算；尚未完成 CTS、
布局布线、多工艺角或完整 SoC 签核。

## 复现

在 npc 中运行：

```sh
make test-execution-units git_commit=
make test-bypass git_commit=
make formal-pipeline git_commit=
make test-execution-core git_commit=
make test-synthesis-target git_commit=
make sta-qualified git_commit=
```

专用 M 程序使用 rv64im_zicsr_zifencei；原有软件目标仍保留 RV64I 编译选项，硬件能力与
软件编译选项分开记录。700 MHz 入口检查真实复位边界、连接、电气负载、数据与门控时序。
