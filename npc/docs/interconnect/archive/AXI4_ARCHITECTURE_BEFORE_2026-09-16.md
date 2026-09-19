> 历史记录，保留原文；当前说明见[同名文档](../AXI4_ARCHITECTURE.md)。

# 完整 AXI4 互连架构

## 当前拓扑

IFU 与 I-cache、LSU 与数据存储层使用本地 typed valid/ready 接口。完整 AXI4 只存在于
cache refill、uncached adapter、core merge、地址路由器和 SoC 边界。

```text
IFU -> I-cache -> refill AXI4 manager --+
                                        +-> core merge -> address router -> targets
LSU -> uncached AXI4 manager -----------+
```

活动 RTL 不保留旧协议兼容层，也不允许 IFU、LSU 或 cache 状态机直接操作 AXI4 通道。

## 模块所有权

- `riscv32_icache_refill_axi4_master`：把一条 line refill 翻译为 AXI4 INCR read burst；
- `riscv32_uncached_axi4_master`：把一次本地 load/store 翻译为单 beat AXI4 事务；
- `riscv32_axi4_core_merge`：仲裁 instruction/data read，数据侧独占 write；
- `riscv32_axi4_address_router`：按地址选择 target，并锁定到事务结束；
- `riscv32_axi4_error_target`：为未映射访问返回 DECERR；
- `riscv32_npc_system`：连接 core、CLINT 和外部系统端口；
- `riscv32_npc_axi`：把内部结构体展开为 ysyxSoC 要求的扁平 AXI4 端口。

## 当前事务能力

- refill read 支持 `LEN/SIZE/BURST/ID/RLAST`；
- uncached load/store 当前均为单 beat；
- core merge 当前最多保留一个 read burst，AR 握手后记录请求来源；
- 地址路由器分别锁定 read 和 write target；
- write address 和 write data 遵循 AXI4 独立握手，不假设二者同拍到达；
- 不支持跨 ID 重排。增加多在途事务时，应新增 ID 跟踪表，不能扩大现有状态机猜测响应来源。

## 后续演进

1. 完成 I-cache 单 MSHR 和 line refill；
2. 用真实计数器测量 burst 长度、等待周期和总线利用率；
3. 根据证据增加多个 MSHR、更多 read outstanding 或独立 instruction/data 系统端口；
4. D-cache、L2、DMA 和 AI accelerator 继续复用完整 AXI4 类型，不重新引入兼容协议。
