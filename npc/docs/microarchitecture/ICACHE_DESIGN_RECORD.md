# I-cache 设计记录

状态：当前实现

## 1. 当前结构

当前I-cache是参数化、组相联、阻塞式L1指令缓存。默认`rv64-edge-ai`配置为4 KiB、2-way、
64 B cache line。默认值用于功能主线，不是固定产品参数；后续必须结合真实前端负载、SRAM
宏和PPA重新选择。

模块分工：

- `riscv32_pma`：判断地址是否可执行、可缓存；
- `riscv32_icache_tag_array`：同步读取tag和line-present元数据；
- `riscv32_icache_data_array`：同步读取fetch word，逐word回填；
- `riscv32_icache_miss_unit`：拥有单个miss事务、refill进度和critical-word响应；
- `riscv32_icache_refill_axi4_master`：把本地refill语义转换为AXI4 burst；
- `riscv32_icache`：拥有lookup流水、命中比较、替换选择和响应仲裁。

## 2. 命中流水

### S0：请求接收

`lookup_req_valid_i && lookup_req_ready_o`时接收PC，同时启动同步tag/data array读取，并把
请求身份和PMA分类写入S1寄存器。

### S1：比较与分类

下一拍使用S1请求和array输出并行比较所有way，得到四类互斥结果：

1. 地址不可执行：返回instruction access fault；
2. 可执行但不可缓存：发起单word uncached访问；
3. cache hit：选择命中way的数据返回IFU；
4. cache miss：选择替换way并交给miss unit。

响应被反压时，S1请求和array输出保持不变。当前只有一个返回口，因此miss存在期间不接收
年轻lookup，避免本地hit和miss响应乱序。

## 3. miss与refill

miss unit按cache line基址发起一个AXI4 INCR burst。每个返回beat到达时：

- 根据beat索引生成`data_write_valid_o`，立即写入data array对应word；
- 若该beat包含原请求critical word，立即产生lookup响应，实现early restart；
- 收到最后一个beat且无错误后，写入tag并置line present；
- refill出错时不安装有效line，并向原请求返回访问错误。

critical word提前交付不代表整条line已经有效。只有最后一个beat成功后metadata才被设置为
present；此前已经返回的其他word只存在于data array中，不能被普通tag hit观察到。

## 4. 替换与一致性

替换优先选择invalid way，否则采用每set轮转指针。替换状态是性能状态，不属于架构状态。

`fence.i`在commit后启动维护流程：若D-cache启用，先clean所有dirty line，再invalidate
I-cache。顺序不能颠倒，否则I-cache可能重新取到尚未写回内存的旧指令。维护期间停止接收
新lookup，并通过前端redirect和epoch丢弃旧路径响应。

## 5. 关键断言

- 同一set同一tag最多命中一个way；
- miss存续期间refill地址、way和原请求身份保持稳定；
- `line_present`只能在完整refill成功后置位；
- AXI错误不能安装有效line；
- 响应反压期间payload保持稳定；
- invalidate完成后所有line-present位清零。

## 6. 后续演进

面向乱序超标量前端的优先顺序：

1. SRAM宏和bank化array；
2. 更宽fetch与跨line取指；
3. 多MSHR和hit-under-miss；
4. miss response排序与frontend tag关联；
5. next-line/stream预取；
6. ITLB和取指访问权限；
7. 与FTQ、uop cache或trace cache的接口评估。

任何扩展都必须保持本地lookup/refill边界，不能把AXI通道直接引入IFU。
