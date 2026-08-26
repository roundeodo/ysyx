# RV64 边缘 AI 处理器架构计划

状态：当前架构决策的唯一依据

最后更新：2026-08-26

## 1. 产品目标

本项目面向高级边缘 AI 设备和本地多模态 AI Agent SoC。CPU负责操作系统、AI runtime、
控制流、地址生成、数据整理和加速器调度；向量单元、矩阵单元和DMA负责规则的大规模计算
与搬运。工作负载依据见[AI处理器工作负载模型](AI_WORKLOAD_MODEL.md)。

最终目标不是继续扩大当前顺序核，而是形成以下结构：

- RV64通用处理器，支持完整异常、中断和虚拟内存；
- 乱序执行、超标量取指/译码/发射/提交；
- 参数化的I-cache、D-cache、TLB和共享缓存；
- 标准RISC-V向量能力及面向AI的数据搬运和矩阵加速接口；
- 以完整AXI4连接内存系统，协议转换只存在于系统边界；
- 能由真实AI workload、性能计数器和PPA结果解释每一项资源。

## 2. 当前主线

当前只维护`rv64-edge-ai`配置，不保留RV32兼容模式，也不保留课程面积或频率签核配置。
源码文件名中的`riscv32_`暂时作为历史工程标识保留；模块语义由`riscv_config_pkg`中的
RV64配置决定。统一重命名必须作为独立机械变更进行，不能与功能修改混在一起。

当前硬件基线为：

- RV64I整数数据通路，32位定长指令；
- Zicsr、Zifencei、M-mode异常和中断闭环；
- 单发射、顺序执行、弹性valid/ready流水线；
- 精确提交，GPR、CSR和架构异常只在commit边界生效；
- 64位core数据通路和64位完整AXI4主接口；
- 参数化、组相联、阻塞式L1 I-cache和write-back D-cache；
- BHT、组相联BTB和RAS组成的控制流预测器；
- EX、EX/MEM和WB结果前递，load结果等待数据返回；
- ysyxSoC仅作为外部验证平台，通过独立宽度转换器接入，不反向限制core内部接口。

## 3. 当前模块边界

### 3.1 前端

- `riscv32_fetch_control_flow_predictor`：预测下一PC，维护BHT、BTB和RAS预测状态。
- `riscv32_ifu`：管理取指请求、frontend tag、epoch和重定向后的过期响应丢弃。
- `riscv32_icache`：负责PMA分类、同步tag/data查询、命中响应、miss调度和invalidate。
- `riscv32_fetch_buffer`：解耦取指返回与译码反压。

预测器不拥有架构PC；IFU不拥有cache替换策略；I-cache不解析AXI通道。下层总线事务由
`riscv32_icache_refill_axi4_master`负责。

### 3.2 顺序后端

- `riscv32_idu`：把指令译码为`decoded_uop_t`。
- `riscv32_decode_stage`：锁存译码结果，切断前端和寄存器读取的组合路径。
- `riscv32_register_read_stage`：锁存GPR读值和指令身份。
- `riscv32_decode_execute_stage`：锁存完成操作数选择与前递后的执行包。
- `riscv32_exu`：执行整数、分支、CSR计算，并生成LSU请求。
- `riscv32_execute_result_stage`：保存执行结果并完成控制流解析。
- `riscv32_lsu`与数据存储子系统：格式化load/store，访问D-cache或uncached路径。
- `riscv32_writeback_stage`：隔离可变延迟完成端和提交端。
- `riscv32_commit`：唯一的架构状态提交边界。

`riscv32_pipeline_hazard_controller`只负责当前顺序流水线的RAW、结构、串行化和恢复控制。
进入乱序阶段后，它将被rename、scoreboard/issue queue、ROB和recovery逻辑替代，而不是继续
扩展成集中式全核控制器。

### 3.3 存储与系统边界

- core内I-cache和D-cache分别拥有独立AXI4 manager；
- `riscv32_axi4_core_merge`负责两个manager的事务仲裁；
- address router只负责地址路由和错误响应；
- ysyxSoC宽度转换器只存在于外部平台边界；
- cache内部使用本地请求/响应结构体，不把AXI协议耦合进IFU或LSU。

## 4. 必须保留的工程能力

以下内容不是课程临时代码，后续设计空间探索和回归仍然需要：

- `cachesim`：从指令/数据地址trace快速评估cache几何参数、miss和TMT趋势；
- `branchsim`：从退休控制流trace评估方向、目标和返回预测算法；
- AXI/APB延迟模型：注入可控反压和响应延迟，验证协议稳定性与性能敏感度；
- DiffTest：验证架构状态；
- RTL定向测试：验证模块协议和边界条件；
- SVA与形式验证：验证流水线flush、握手稳定性、无重复提交等不变量；
- 性能监视模块：只在仿真构建中实例化，不进入综合core。

模型结果只能用于筛选候选方案。最终决策必须由同一commit、同一workload下的RTL功能、
周期、频率和面积共同验证。

## 5. 已删除的历史方向

主线不再维护以下内容：

- RV32E/RV32I课程签核配置；
- 通过极小cache或关闭功能换取面积数字的配置；
- 为追逐单个1 GHz目标而增加、删除流水级的临时分支；
- 不同协议或不同延迟模型之间不可比较的性能排行榜；
- 已被RV64主线替代的P2/P3双配置迁移文档；
- 生成的综合、STA、波形、缓存trace和临时测试目录。

删除这些内容不等于忽略PPA。后续PPA优化必须从架构瓶颈出发，并保留功能、协议和精确
异常语义。

## 6. 演进路线

### P3：RV64顺序流水线基线

当前已经具备主要结构，剩余工作是收敛和验证：

1. 固定RV64I/Zicsr/Zifencei/M-mode语义；
2. 跑通RTL单元测试、DiffTest和代表性软件；
3. 记录前端、分支、RAW、LSU和cache miss停顿；
4. 清除重复控制、过期接口和仿真专用逻辑泄漏；
5. 建立可重复的PPA和性能基线。

### P4：宽度为1的乱序核心

先改变执行语义，不急于增加发射宽度：

1. 引入物理寄存器、rename map和free list；
2. 引入ROB，所有异常和架构状态在ROB头精确提交；
3. 引入整数issue queue、wakeup/select和结果广播；
4. 把LSU扩展为load queue、store queue和store commit；
5. 用checkpoint恢复分支错误路径；
6. 保持单发射，以降低首次乱序验证复杂度。

### P5：超标量乱序

在P4稳定后逐步扩宽：

1. 取指、译码和rename宽度参数化；
2. 多发射端口和多执行单元；
3. 多bank寄存器堆、旁路和结果网络；
4. 多MSHR、store buffer和内存级并行；
5. 更强的TAGE类方向预测、BTB层次和RAS恢复；
6. 按瓶颈决定ROB、issue queue、LSQ和cache容量。

### P6：AI异构扩展

1. 加入RVV兼容向量执行接口；
2. 加入DMA、命令队列和加速器完成队列；
3. 评估一致性端口与显式软件管理两种数据共享方式；
4. 用tokenizer、GEMV、KV cache和runtime queue负载驱动设计；
5. 最终以首token时间、tokens/s、能效和系统响应时间评价方案。

## 7. 决策规则

1. 先证明瓶颈，再增加资源；不能用“未来可能需要”代替数据。
2. 参数化服务于经过验证的配置集合，不保留无法测试的兼容分支。
3. 接口表达模块语义，AXI等外部协议只在适配边界出现。
4. 每个事务必须定义开始、完成、反压稳定性、flush和错误处理。
5. 推测状态、可替换状态、架构状态和仿真状态必须分开。
6. 每次架构修改必须同时更新断言、测试、性能事件和设计记录。
7. 性能、面积和频率必须对应同一RTL、同一约束和同一workload，禁止跨口径比较。

