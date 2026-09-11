# I-cache设计记录

> 历史设计记录：各章节反映不同阶段，早期参数和待办不一定适用于恢复的 RV32 快照。
> 当前配置、实现边界及面试表述见 [RV32 简历核对](../interview/RV32_RESUME_AUDIT.md)。

状态：RTL实现完成，验证收口中

所有者：`riscv32_icache`

关联决策：当前计划P1、D004和D005；历史计划D024

最后更新：2026-08-25

## 1. 问题和目标

当前IFU的每次取指都会经过SoC存储路径。已有基线数据显示，绝大多数活动周期用于
等待指令响应，因此需要使用本地指令缓存为重复取指提供数据。

第一个实现检查点必须满足：

- 保持当前RV32I功能行为和valid/ready反压契约。
- 流水线和miss机构可用时，每周期接受一个lookup请求。
- lookup命中采用固定的一周期响应延迟，并允许稳定命中时每周期接受一个请求。
- cache line大于一条指令，并优先填充请求对应的word。
- redirect后丢弃过期前端响应，同时不得违反下层总线协议。
- 只缓存可执行、可缓存、幂等的存储区域。
- 第一版就支持`fence.i`失效操作和性能事件。

本检查点不实现多miss并发、预取、一致性、ECC和虚拟地址转换。下层refill使用完整
AXI4 INCR burst；多ID并发和乱序返回留到后续非阻塞cache检查点。

## B4课程面积配置与长期配置的边界

当前RV32I工程评审配置为128B容量、direct-map、16B line。该配置的目的不是替代本文后续
记录的长期8KiB起步目标，而是在DFF/锁存器实现小容量array的阶段获得可解释的性能面积点：

- Nangate45综合总面积低于当前RV32I的32000 um^2工程评审线；
- 保留真实同步array读、tag比较、blocking miss和AXI4 refill协议，不用组合存储器或综合
  选项伪造面积结果；
- 在当前单MSHR结构下，允许已写入当前refill line的word被后续顺序取指直接读取，减少
  critical word返回后仍等待整行完成造成的阻塞。

同一版RTL、MicroBench `test`和NanGate45流程下，64B/direct/16B的面积、IPC和Fmax分别为
28068.320 um^2、0.091934和536.113 MHz；128B/direct/16B分别为31222.282 um^2、
0.116519和547.646 MHz。增加11.24%面积换来29.47%的综合吞吐代理提升，因此选择128B。
这一结论只适用于当前标准单元小容量array和课程workload，不能推断采用SRAM宏的长期配置。

## 2. 当前课程配置与长期配置

当前检查点使用命名配置`YSYX_RV32_BASELINE`。表中的当前值用于B4课程面积与功能验证；
长期值描述采用SRAM宏、流水前端和非阻塞miss结构后的目标，不是当前RTL的默认参数。
两者共用同一套语义参数和派生类型，不能把地址切片或某一组参数散落在子模块中。

| 属性 | 参数或派生关系 | 当前课程值 | 长期目标 | 说明 |
| --- | --- | ---: | ---: | --- |
| 容量 | `ICACHE_CAPACITY_BYTES` | 128 B | 8 KiB起步 | 当前array由标准单元实现，长期改用SRAM宏 |
| 路数 | `ICACHE_WAY_COUNT` | 1 | 2或更多 | 当前direct-map用最小tag比较和替换成本换取容量 |
| Cache line | `ICACHE_LINE_BYTES` | 16 B | 32或64 B | 当前配置在命中率和refill尾部之间取得实测平衡 |
| 单次取指字节数 | `ICACHE_FETCH_BYTES` | 4 B | 参数化扩宽 | 当前匹配不支持压缩指令的单发射RV32I前端 |
| Set数量 | `CAPACITY_BYTES / (WAYS * LINE_BYTES)` | 8 | 参数派生 | 由容量、路数和line大小唯一派生 |
| 每行取指word数 | `LINE_BYTES / FETCH_BYTES` | 4 | 参数派生 | 由line大小和取指粒度唯一派生 |
| Offset位数 | `$clog2(LINE_BYTES)` | 4 | 参数派生 | 选择cache line内的一个字节 |
| Set index位数 | `$clog2(SETS)` | 3 | 参数派生 | 选择一个set |
| Tag位数 | `PADDR_WIDTH - OFFSET_BITS - SET_INDEX_BITS` | 25 | 参数派生 | 区分映射到同一set的不同cache line |
| 未完成miss数 | `ICACHE_MSHR_ENTRIES` | 1 | 至少2 | 当前采用blocking cache，长期支持hit-under-miss和多miss并发 |

构建配置值放在`riscv_config_pkg`中，共享派生类型放在`riscv32_pkg`中；模块局部派生量
放在其所有者模块中。`NPC_ICACHE_LINE_BYTES`至少支持4/8/16/32/64B line，每组配置进入
独立构建目录。展开阶段
必须检查容量、路数、line大小和set数量是否合法，line不小于一个取指word，并且数组
规模与地址字段位宽一致。未来RV64配置只能修改命名配置和必要的接口宽度，不能复制一套
I-cache RTL。

## 3. 所有权边界

| 模块 | 拥有 | 不拥有 |
| --- | --- | --- |
| `riscv32_ifu` | next-PC顺序、redirect epoch、向译码级交付 | tag、替换策略、refill协议 |
| `riscv32_ifu`内部响应寄存器 | 保存已返回但尚未交付的指令，并处理redirect epoch | cache lookup和miss策略 |
| `riscv32_icache` | lookup流水线、命中判断、替换和失效协调 | AXI通道细节 |
| `riscv32_icache_tag_array` | tag和cache line present状态 | 替换策略 |
| `riscv32_icache_data_array` | 缓存的指令word | tag有效性和refill顺序 |
| `riscv32_icache_miss_unit` | 单个未完成miss、关键word返回、整行完成 | 下层AXI信号时序 |
| `riscv32_icache_refill_axi4_master` | 将一次line refill转换为AXI4读burst | cache命中策略 |
| `riscv32_pma` | 静态地址属性 | 动态权限和页表转换 |

面向core的cache接口保持协议无关。AXI只存在于cache下方的refill adapter中，使未来
更换cache、crossbar、AXI4 burst adapter或TileLink adapter时不需要重写IFU控制。

## 4. 接口契约

### 4.1 IFU到I-cache的lookup

- 只有`lookup_req_valid_i && lookup_req_ready_o`时请求才被接受。
- 请求携带PC、fetch epoch和`frontend_tag`。valid有效且ready无效期间，这些字段必须稳定。
- `lookup_resp_valid_o && !lookup_resp_ready_i`期间响应必须稳定。
- 响应重复携带PC、epoch和`frontend_tag`，使IFU能够匹配请求并拒绝过期工作，不依赖响应
  返回的固定先后时间。
- 除非模块复位取消事务，每个被接受的lookup必须产生且只能产生一个响应。

### 4.2 Miss unit到refill adapter

- 一次line请求携带对齐后的line地址、请求word index，以及miss/refill边界本地使用的
  refill transaction index。miss表项保留原始前端epoch和tag，refill adapter不得解释它们。
- Adapter为整条line发出一次32-bit AXI4 INCR burst，beat数由
  `ICACHE_LINE_BYTES / ICACHE_FETCH_BYTES`派生。AXI地址从line基址递增，不改变协议顺序来
  人为实现critical-word-first。
- 每个返回beat标明对应的line word index。请求word到达时miss unit可以立即返回关键word，
  但只有当前配置的全部line word写入成功后才能将tag `present`置位。
- ysyxSoC SDRAM边界按32B原生BL8边界把AXI burst切成最少数量的物理连续读段。8B、16B、
  32B对齐line分别映射为2、4、8个连续数据beat；短段在最后一个所需beat后发送
  BURST TERMINATE，跨32B边界的事务必须拆段，不能使用SDRAM回绕数据冒充AXI INCR地址。
- 下层存储错误必须产生错误响应，且不能使部分填充的cache line有效。

### 4.3 失效操作

- `fence.i`启动完整I-cache失效事务。
- 失效逻辑占用tag present写端口时，必须反压新的lookup。
- 只有全部set和way的present位清零后才能报告完成。

## 5. Lookup流水线

### S0：接受请求并生成索引

- 接受一个协议无关的lookup请求。
- 使用PMA对地址分类。
- 对可缓存请求计算tag、set index和word index，并启动同步tag/data阵列读取。
- 对不可缓存但可执行的请求绕过lookup，通过miss/refill路径发出单word非缓存访问。
- 对不可执行或无效区域产生instruction access fault。

### S1：同步阵列返回

- 在阵列输出旁保存原始PC、cache tag、frontend epoch、`frontend_tag`和PMA属性。
- 下游反压期间，metadata和data必须保持属于同一请求且同步移动。

### 响应组合级：比较和选择

- 每路并行比较：`way_present && way_tag == request_tag`。
- 零路匹配表示miss，恰好一路匹配表示hit，多路同时匹配必须触发数据损坏断言。
- 命中时选择请求word并通过响应通道返回。
- miss时选择victim、分配单miss unit并阻塞新的miss。

S0握手所在上升沿启动同步array读取；该沿后S1身份寄存器和array输出寄存器同时更新，比较与
响应在随后一个周期内可用。因此从请求接受到响应可用是一周期延迟，并不存在独立的S2
寄存器。稳定命中吞吐为每周期一个lookup；多路配置始终并行比较各way tag。

## 6. 替换和Refill

victim选择优先使用invalid way。两路均有效时，每个set使用一个替换位选择victim；
一次完成的hit或refill更新替换位，使下一次优先选择另一way。更新依据必须是完成的
lookup/refill，不能仅依据收到请求。

第一版miss unit是blocking结构，包含一个等价于MSHR的表项，保存：

- 对齐后的line地址和请求word index。
- victim set和way。
- 原始PC、frontend epoch、`frontend_tag`和refill transaction index。
- 已返回word的present vector和第一个错误响应。
- 关键word响应是否已经发送。

refill beat返回后立即写data word，metadata最后提交，从而防止lookup命中尚未完整填充的
cache line。early restart在关键word到达后立即返回，同时miss unit继续填充其余word。

当前实现除early restart外，还允许后续lookup读取“正在refill的同一line中已经写入”的
word。miss unit输出当前line基址、victim way和`refill_word_present_vector`；I-cache只有在
请求属于该line且目标word对应present位为1时才接受请求，并从已写入的victim way读取。
这条路径不复制cache-line数据，也不允许另一条line分配第二个miss，因此只是单MSHR下的
active-refill word reuse，不等价于通用hit-under-miss或非阻塞cache。

## 7. Redirect和Fence语义

每个被接受的fetch携带当前`fetch_epoch_q`。redirect使epoch递增。旧epoch响应仍然完成
cache和总线握手，但IFU不得将其交给译码级。未来miss重叠或下层响应乱序时，这条规则
仍然成立。

`fence.i`必须在允许年轻指令继续取指前使全部I-cache line失效。即使第一版SoC没有
一致性D-cache，也要明确定义该操作，因为自修改代码和未来D-cache接入都需要明确的
指令可见点。

## 8. PMA策略

第一版PMA分类器采用当前ysyxSoC物理地址图：

- flash XIP、PSRAM、SDRAM等普通可执行存储区域在满足幂等条件时可以缓存。
- 小容量SRAM和MROM在第一版保持非缓存，因为其直接访问延迟较低，且有利于确定性的
  启动和调试。
- CLINT、UART、GPIO、SPI寄存器、PS/2、VGA及其他MMIO全部不可缓存且不可执行。
- 未映射地址产生instruction access fault。

准确地址范围只允许在`riscv32_pma`中定义一次，IFU和下层adapter不得重复cache策略。

## 9. 正确性不变量

- cache hit必须恰好存在一个匹配且present的way。
- 只有全部refill word成功后cache line才能变为present。
- 一个被接受的lookup最多产生一个响应。
- 旧epoch响应不得到达译码级。
- valid/ready接口停顿时payload必须稳定。
- 单miss表项被占用时不得被覆盖。
- 第一版refill adapter最多存在一个未完成下层读取。
- 下层错误不得安装有效cache line。
- 失效操作和refill metadata提交不得同时占用同一tag array写端口。
- 不可缓存和不可执行区域不得分配cache line。

## 10. 时序和快速路径

S0/S1/S2寄存器边界避免PMA分类、SRAM访问、tag比较、word选择和fetch-buffer反压形成一条
组合路径。响应通道可以同周期流入空fetch buffer，buffer寄存器提供阻塞后备路径。
下层refill流量不位于hit路径。

early restart是第一条miss快速路径，在不允许部分cache hit的前提下降低前端可见miss延迟。
hit-under-miss、多MSHR、way prediction和prefetch只有在计数器证明其收益且顺序流水线稳定后
才进入后续检查点。

## 11. 性能事件

| 事件 | 精确定义 | 用途 |
| --- | --- | --- |
| lookup request | IFU lookup握手成功 | 前端需求数 |
| hit response | cache-hit响应握手成功 | 命中率 |
| miss allocation | miss表项从空闲变为占用 | miss率 |
| critical-word response | early-restart响应握手成功 | 前端可见miss延迟 |
| refill beat | 一个下层word响应握手成功 | refill流量 |
| refill completion | 完整line metadata提交 | line fill数量 |
| uncached request | PMA路由的非缓存访问被接受 | bypass流量 |
| lookup stall cycle | 有效lookup无法被接受的周期 | 前端结构阻塞 |
| miss busy cycle | miss表项被占用的周期 | blocking miss代价 |
| stale response | 响应epoch与当前epoch不同 | 错误路径代价 |
| invalidate cycle | `fence.i`失效过程活动的周期 | 维护操作代价 |

## 12. 验证计划

1. 对每个set、word和tag边界测试地址拆分。
2. 测试cold miss、所有way hit、invalid-way选择、替换选择和set冲突。
3. 按关键word优先顺序返回refill word并验证early restart。
4. 分别对lookup响应、refill请求和refill响应施加反压。
5. 在每个refill beat注入下层错误，验证不会安装cache line。
6. 在S0、S1、hit响应阻塞及每个miss/refill状态触发redirect。
7. 在空cache、满cache和refill进行中执行`fence.i`。
8. 断言通道稳定、请求响应守恒、way hit one-hot和整行提交。
9. 分别在cache启用和禁用状态运行cpu-tests、DiffTest、RT-Thread和microbench。
10. 对比IPC、IFU response-wait周期、命中率、miss penalty和综合时序。

## 13. 开源设计研究

| 来源 | 学到的机制 | 本地决策 |
| --- | --- | --- |
| Ibex I-cache | 两级lookup、fill buffer、关键word优先refill、失效和pass-through | 采用固定分级lookup、early restart、显式失效和非缓存bypass；暂缓多fill buffer |
| BOOM fetch unit | fetch packet和flow-through fetch buffer解耦I-cache响应与译码 | 采用独立flow-through fetch buffer；第一版保持4字节取指宽度 |
| XiangShan WayLookup/I-cache | 分离main pipeline、array、miss unit、replacer、control、metadata queue、refill广播和flush/反压 | 采用模块所有权分离和响应身份；暂缓metadata queue和多请求refill广播 |
| OpenTitan硬件设计文档 | Theory of Operation、接口表、设计细节、DV计划和断言 | 采用这种记录结构，并要求实现前先定义验证目标 |

## 14. 逐文件实现顺序

下面的顺序按类型依赖、局部可验证性和集成风险排列。禁止跳到IFU或core接线后再回头补
package和下层事务契约。

### 检查点A：冻结公共类型

1. 完成`npc/vsrc/riscv32/common/riscv32_pkg.sv`中的`ICACHE-PKG-1`至
   `ICACHE-PKG-5`。
2. 只定义几何参数、派生位宽、索引类型、PMA属性、lookup/refill通道和PMU事件，不在
   package中加入任何状态机或策略逻辑。
3. 单独编译package，确认所有参数组合和结构体位宽合法后，才能继续下一文件。

### 检查点B：地址属性和存储阵列

4. 完成`core/frontend/riscv32_pma.sv`，先验证每个地址区域的起点、终点和边界外地址。
5. 完成`core/frontend/riscv32_icache_tag_array.sv`，验证同步读、metadata写、复位失效和
   同地址读写语义。
6. 完成`core/frontend/riscv32_icache_data_array.sv`，验证按way、set和word索引的同步读，
   以及refill每周期写入一个word。
7. 此阶段只测试阵列，不实现hit判断、替换或miss。两个阵列都通过局部测试后再进入下层
   访存路径。

### 检查点C：下层refill事务

8. 完成`core/frontend/riscv32_icache_refill_axi4_master.sv`。第一版通过一次完整AXI4
   INCR burst取回整条cache line。总线按递增地址返回，
   `critical_word_index`只用于识别关键字到达并支持early restart，不虚构critical-word-first顺序。
9. 验证AR反压、R反压、`SLVERR`、`DECERR`、word索引回绕、请求和响应载荷稳定性。
10. 完成`core/frontend/riscv32_icache_miss_unit.sv`，保存唯一miss的身份、victim位置、
    已返回word集合和首个错误。
11. 验证关键word提前响应、部分refill不可见、整行成功后才提交metadata，以及错误发生后
    不安装有效cache line。

### 检查点D：I-cache主体

12. 完成`core/frontend/riscv32_icache.sv`，按顺序实现PMA路由、S0/S1/S2 lookup流水、
    两路tag比较、hit数据选择、victim选择、refill接入和`fence.i`失效。
13. 先测试cold miss和稳定hit，再测试set冲突、invalid-way优先、替换位、下层错误、
    redirect和失效；不要一次写完整模块后才开始验证。
14. 完成`core/frontend/riscv32_fetch_buffer.sv`，实现cache响应与译码反压解耦、空队列
    同周期旁路、阻塞后的寄存器回退，以及旧epoch响应丢弃。

### 检查点E：接入现有core

15. 修改`core/riscv32_ifu.sv`，用协议无关lookup通道替换IFU直接拥有AXI读事务的逻辑；
    IFU继续拥有PC、redirect epoch和向译码级交付的顺序。
16. 修改`core/riscv32_core.sv`，只完成结构化接线和事件汇总，不把cache策略重新写进core。
17. 修改`core/riscv32_pmu.sv`，连接lookup、hit、miss、refill、stall和stale response事件。
18. 只有确实需要软件读取新增计数器时，才修改`core/riscv32_csr_file.sv`增加CSR映射；
    仿真专用计数器不应无条件扩大可综合CSR状态。
19. 每个新增模块通过局部编译后，按package、PMA、array、adapter、miss unit、cache、
    fetch buffer的依赖顺序加入`npc/vsrc/riscv32/filelist/filelist.f`。在此之前保持活动
    filelist可构建。

### 检查点F：完整回归和性能比较

20. 依次运行lint、NPC功能测试、cpu-tests、DiffTest、RT-Thread和microbench。
21. 检查lookup请求数、hit与miss总数、refill数量、IFU等待周期和提交指令数之间的守恒
    关系，并将结果追加到[`EXPERIMENT_LOG.md`](../verification/EXPERIMENT_LOG.md)。
22. 完成综合和STA，确认S0/S1/S2确实切断PMA、阵列、tag比较和响应反压之间的长组合路径。
23. 完整AXI4 burst属于当前基础实现；只有功能、计数器和时序基线稳定后，才评估更多MSHR、hit-under-miss、
    prefetch、way prediction和更宽取指。

## 15. 仍需解决的问题

- 首次测量后SRAM/MROM是否应继续保持非缓存。
- 何时从单未完成refill扩展到多MSHR，以及如何分配和回收AXI ID。
- 两项或四项fetch buffer中哪一种更适合P4流水线。
- 哪种替换策略相对每set一个替换位能产生可测量收益。
- 是否应在加宽取指带宽之前引入压缩指令。

## 16. 当前实现检查点

截至2026-08-13，检查点A至E的RTL和结构接线已经完成：公共类型、PMA、tag/data array、
AXI4 refill master、blocking miss unit、S0/S1/S2 lookup、fetch buffer、IFU接入、core接线、
PMU事件和`fence.i`失效路径均已进入活动filelist。活动RTL中不再保留AXI4-Lite兼容实现。

当前证据：

- `make lint-npc PROJECT=riscv32`通过，剩余信息为非致命未使用字段/参数告警；
- `make sim-npc PROJECT=riscv32 IMG=../am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin`
  命中good trap；
- dummy运行中出现错误路径响应丢弃，说明redirect epoch路径被实际触发。

尚未完成检查点F。cold miss、所有way、set冲突、critical-word early restart、每个refill
beat错误、各阶段redirect、refill期间`fence.i`以及cache开关A/B仍需定向验证；cpu-tests、
DiffTest、RT-Thread、microbench、综合和STA也必须基于已提交版本记录后，P1才能标记为完成。

## 17. RV32I性能默认配置与`fence.i`一致性验证

2026-08-22将RV32I默认I-cache从`64B/1-way/8B line`调整为
`1KiB/1-way/8B line`。本次只改变几何参数，不修改IFU lookup、miss unit refill或AXI4
协议。RV32配置继续使用`rv32i_zicsr_zifencei`，没有切换到RV32E。

选择依据如下：

- direct-mapped避免增加多路tag比较、way选择和替换状态，保持命中路径简单；
- 8B line已经实际使用AXI INCR burst和SDRAM连续读，同时不会让当前blocking miss unit
  长时间等待无关的尾部refill；
- 同一MicroBench `test`中，1KiB相对64B将miss从172752降至11927，PMU窗口IPC从
  0.082929提高到0.236549，Total从71.005ms降至29.714ms；
- 1KiB不再以23000um^2课程面积线为默认目标。需要复现实验用小面积配置时，应通过
  `NPC_ICACHE_CAPACITY_BYTES=64`显式选择，而不是在RTL中保留第二套实现。

自修改代码会同时产生两个物理内存副本：store通过数据通路改写SDRAM，而I-cache中已经
命中的旧cache line不会被这次store自动修改。RISC-V在软件执行`fence.i`之前允许后续取指
继续观察旧副本；因此“未执行`fence.i`仍读到旧指令”是复现实验，不是ISA错误。

当前`fence.i`实现按以下顺序建立可见点：

1. IDU将`MISC-MEM/funct3=001`译码为`SYS_FENCE_I`；
2. 指令到达commit边界后，core产生前端redirect，并保持`icache_invalidate_req`；
3. I-cache立即停止接收新lookup，排空S1 lookup和正在进行的miss/refill；
4. invalidate状态机逐set、逐way把tag metadata的`present`清零。tag和data位本身不用清零，
   因为`present=0`已经保证旧内容不能命中；
5. `invalidate_done`返回后撤销pending请求，IFU从`fence.i`的`next_pc`重新取指。此后对被
   修改地址的访问必然miss并从SDRAM取回新指令。

定向测试位于`am-kernels/tests/cpu-tests/tests/`：

- `icache-smc-no-fence.c`先执行返回1的函数，再把第一条指令改成返回2，但不执行
  `fence.i`；第二次调用仍返回1，证明旧I-cache副本确实存在；
- `icache-smc-fence-i.c`执行同样的store后插入`fence.i`；第二次调用返回2，证明整片失效
  和重新取指生效。

两项测试均在`riscv32-ysyxsoc-sdram`环境、1KiB默认I-cache下命中good trap。SDRAM启动代码
在从Flash复制运行镜像后、首次跳到SDRAM前也执行`fence.i`，原因与运行时自修改代码相同。
