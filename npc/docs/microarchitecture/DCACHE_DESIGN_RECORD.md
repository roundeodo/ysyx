# D-cache 设计记录

状态：当前实现

## 1. 当前结构

当前D-cache是参数化、组相联、阻塞式、write-back/write-allocate的L1数据缓存。默认
`rv64-edge-ai`配置为4 KiB、2-way、64 B cache line。默认容量用于RV64功能主线，后续由
真实数据工作集、SRAM宏和PPA共同决定。

模块分工：

- `riscv32_data_memory_subsystem`：根据PMA把访问路由到D-cache或uncached master；
- `riscv32_dcache`：lookup流水、命中处理、替换和clean遍历；
- `riscv32_dcache_tag_array`：保存tag、present和dirty；
- `riscv32_dcache_data_array`：同步读、byte strobe写；
- `riscv32_dcache_miss_unit`：执行victim writeback和refill；
- `riscv32_dcache_line_axi4_master`：把line读写转换为AXI4 burst。

LSU只表达load/store语义，不拥有cache状态，也不直接驱动AXI。

## 2. lookup流水

S0握手接收`data_memory_req_t`并启动同步tag/data array读取。S1使用保存的地址、操作类型、
byte strobe和array输出完成命中比较。

命中时：

- load返回命中word，LSU负责按访问大小和符号属性格式化；
- store按byte strobe合并数据，写data array并置dirty；
- store hit后的紧邻同word访问通过显式bypass看到新字节，不能依赖SRAM的read-during-write
  行为。

miss或clean存续期间，cache不接收新的lookup。当前设计强调清晰的事务所有权和精确异常，
不支持hit-under-miss。

## 3. write-back miss流程

miss时先选择invalid way；若所有way有效，则使用每set轮转指针选择victim。

1. victim有效且dirty：逐beat读取victim line并发起AXI写burst；
2. 等待写响应，错误则向原请求报告access fault；
3. 发起目标line的AXI读burst；
4. 每个read beat到达时写入data array；
5. 完整line成功后安装tag、置present并清dirty；
6. 重放原load/store并返回结果。

AXI写地址和写数据通道独立握手；line master必须分别保存两条通道的进度，不能假设AW和W
同拍完成。

## 4. clean与fence.i

`clean_req_i`启动全cache遍历。每条dirty line写回成功后清dirty；全部set和way完成后才拉高
`clean_done_o`。任一写回错误通过`clean_access_fault_o`报告。

commit后的`fence.i`先等待D-cache clean，再invalidate I-cache。这保证软件写入的新指令先
到达统一内存视图，然后前端才重新取指。

## 5. 正确性不变量

- present、dirty和tag必须作为同一个line状态一致更新；
- clean line不能发起无意义writeback；
- dirty victim写回完成前不能被新line覆盖；
- refill错误不能安装present line；
- store byte strobe之外的字节保持原值；
- 一个请求只能产生一个响应；
- uncached访问不能修改D-cache元数据。

## 6. 与I-cache共享下层内存

I-cache和D-cache分别输出独立AXI4 manager，由系统层merge模块仲裁。cache内部不感知另一侧
请求。当前顺序核的阻塞式cache限制了并发度；未来增加多MSHR和store buffer后，仲裁器必须
按完整AXI事务保持归属，并利用不同AXI ID支持并发返回。

## 7. 后续演进

1. SRAM宏和bank化data array；
2. store buffer与store-to-load forwarding；
3. 多MSHR和non-blocking load；
4. load queue、store queue和内存依赖预测；
5. writeback queue与独立refill/writeback通道；
6. DTLB、页权限和精确page fault；
7. L2、一致性和DMA/AI accelerator访问策略。

