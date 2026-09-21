# RV32 数据访存：原理与电路结构

当前工作树，2026-09-21。`rv32-baseline` 的 D-cache 为 256 B、两路、16 B/行，
采用阻塞式写回、写分配。参数从 [Makefile](../../Makefile) 统一进入 RTL。

## 请求路径与状态归属

| 模块 | 电路与源码顺序 |
| --- | --- |
| `riscv32_data_mem` | PMA 分类 → 本地/缓存/非缓存接口输出及 AXI 选择 → 路由下一状态 → 更新 → 子模块连接 |
| `riscv32_dcache` | 共享反馈接口 → 请求与阵列读选择 → 同步阵列 → 查询/store 旁路与替换 → hit/miss 响应 → clean 状态机 → 写端口反馈 → miss/AXI 连接 → 事件 |
| `riscv32_dcache_tag_array` | 每组/路保存 tag、present、dirty，同步读取；写口在回填、store 和 clean 时更新 |
| `riscv32_dcache_data_array` | 按路/组/字保存数据，同步读取、字节掩码写入；阵列自身不处理 store 旁路 |
| `riscv32_dcache_miss_unit` | 单事务上下文、被替换行缓冲、错误与响应状态；输出 → 下一状态 → 更新 |
| `riscv32_dcache_axi` | 独立读回填与写回控制，共用完整 AXI 输出；输出 → 各通道下一状态 → 更新 |
| `riscv32_uncached_axi` | 一个请求上下文；输出 → 读/写下一状态 → 更新，AW 与 W 独立握手 |

PMA 决定访问权限与缓存属性。普通可缓存请求去 D-cache；设备及非缓存内存去单 beat
适配器；无权限地址本地产生 access fault。路由从请求握手保持到响应握手，响应完成拍
允许接收下一请求；不额外复制一份 LSU 请求队列。

## 同步查询、store 与旁路

阵列仅在请求握手时启动 lookup 同步读，同时保存 S1 身份。响应反压时读输出与字节旁路一起保持。
各路并行比较 tag；load hit 返回目标字，store hit 只在响应握手时写对应字节并置 dirty。

store hit 可以与下一请求的阵列读取同沿发生。为处理读写同地址时返回旧数据的情况，
保存这次 store 的组、路、字索引、数据与掩码，在下一查询中合并匹配字节；同组的 dirty
信息也同步旁路，防止替换时漏写回。这组寄存器有明确的数据相关用途。

miss 优先选择无效路，否则按每组轮转指针选路。指针在新行成功安装时推进，不在 hit 时更新。

## miss 与 clean

一次 miss 保存原请求及替换位置。干净替换在分配拍直接发 refill；脏替换在分配拍启动
首字同步读，随后逐拍采集整行。最后一个字返回时直接补入行数据并发出写回请求；
受阻时完整行已保存，进入发送状态继续保持，不强制多等一拍。

普通脏替换在写回请求被接收的下一拍发 refill，并使旧行失效；B 响应独立跟踪，
读回填可以与尚未结束的写回重叠。这个发起交接拍不是 AXI 协议要求，同拍方案及暂缓原因见
[本轮取舍](../verification/RV32_REFINEMENT_2026-09-21.md)。clean 只写回，不发 refill。
安装新行前必须确认 B 和全部 R 均无错。普通 miss 的写回失败不恢复旧行，返回 access fault；
clean 写回失败则保留该行的 dirty 状态。

回填用 INCR burst 从行首顺序读取，各 beat 写阵列；store miss 在目标字处合并待写字节。
最后必要的 R/B 到达且整行无错时，当拍安装新 tag/present/dirty 并交付响应；反压后只保持响应，
不重复安装。响应等待整行完成，不做关键字提前返回，
因此响应完成也能用作本次数据 AXI 占用结束的边界。

clean 的状态为“空闲、检查组内脏路、等待写回”。一次读出组内所有有效/dirty 位，
跳过无需写回的路；检查完当前组的同拍读取下一组。写回 B 成功时清 dirty，失败终止并报告，
最终操作当拍给出 done。clean 占用期间阻止普通请求。

| 保存的状态 | 用途及释放条件 |
| --- | --- |
| S1 请求与有效位 | 关联同步阵列输出；hit 响应握手或 miss 分配后释放 |
| store 旁路记录 | 修正紧随 store 的同步读结果；store 与新查询同沿时建立，保持到该查询离开 S1 |
| miss 上下文与整行缓冲 | 替换、写回和回填全过程保持，完成响应被接收后释放 |
| clean 组/路索引和错误位 | 完整遍历期间推进；完成后回到空闲 |
| AXI 地址/数据待发状态 | 行数据由 miss unit 保持到 B 握手，adapter 不再复制整行；保持各通道反压载荷，不能把 AW 与 W 当成一次共同握手 |

## 接口与取舍

阵列读口优先服务被替换行读取与 clean，写口优先服务 miss；正常 store hit 只在 miss 空闲时发生。
响应及总线载荷在反压时保持。clean 在没有 LSU 事务时也会发出 AXI 写回。
系统按各通道实际 valid 选择 D-cache 请求，旧 R/B 按事务路由返回；
不以年轻请求的发射允许信号选择地址。

单 miss 简化了顺序和错误处理，代价是访存期间阻塞。没有 store buffer、写回队列或多 MSHR。
I/D 共用总线的仲裁与目标路由见[互连说明](../interconnect/AXI4_ARCHITECTURE.md)。
FENCE.I 的维护顺序由[流水线说明](PIPELINE_DESIGN_RECORD.md)中的控制器统一负责。

## 验证入口

`test-dcache` 覆盖命中、store 旁路、脏替换与全组/路 clean；`test-dcache-miss` 检查最后一字
旁路、整行保持、R/B 完成、错误与反压；`test-dcache-axi` 检查 AW/W/AR 独立反压和响应身份；
`test-uncached` 检查连续事务交接。当前回归与测量见
[缓存交接实测](../verification/RV32_REFINEMENT_2026-09-21.md)。
[历史设计与测量](archive/DCACHE_DESIGN_RECORD_BEFORE_2026-09-16.md)仅供追溯。

uncached 与 I-cache AXI adapter 空闲时直接发出请求，反压时由上下文保持。
uncached 成功响应交付的同拍也可接收下一请求，旧响应与新地址分别取值。
本轮周期与面积验证见[优化记录](RV32_CYCLE_OPT_DESIGN.md)。
