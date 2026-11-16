# RV32 总线与系统连接

当前 `rv32-baseline`。核内请求使用类型明确的 valid/ready 接口，AXI 协议由缓存与
非缓存适配器处理；纯核输出独立的 instruction/data AXI 端口。

## 数据路径与模块职责

| 模块 | 电路与状态归属 |
| --- | --- |
| `icache_axi` | 行回填转换为 INCR 读 burst，保持反压请求与响应 |
| `dcache_axi` | 独立处理行回填和脏行写回，读写通道可重叠 |
| `uncached_axi` | 空闲时直通、反压时保存一个请求，发起单 beat 读或写，AW/W 独立握手 |
| `axi4_arbiter` | I/D 读轮询；从展示 ARVALID 起锁定来源，直到 RLAST 握手；写通道由数据侧独占 |
| `axi4_router` | 地址比较 → 请求/响应选择 → 读写下一状态 → 更新；两个方向分别保存目标 |
| `axi4_clint` | 本地定时器、比较寄存器和独立 AXI 读写状态机；中断返回核 |
| `reset_controller` | 异步进入复位，两级上升沿同步后在下降沿释放 |
| `core_reset_boundary` | 综合用封装，只连接复位控制器与纯核 |
| `npc_system` | 连接复位、纯核、I/D 仲裁、地址路由与 CLINT |
| `axi4_soc_width_converter` | 当前 32→32 位纯组合映射；其他配置的 64→32 位分支保留独立读写状态机 |
| `npc_axi` | 将内部结构体映射到 ysyxSoC 的扁平引脚 |

D-cache 和 uncached 在数据存储子系统内合并，再与 I-cache 共享外部读端口。
系统将 `0x02000000–0x0200ffff` 路由至本地 CLINT，其余请求默认交给外部 SoC；
独立 `axi4_error_target` 未接入当前路径，现保存在 `experiments/interconnect/`，
不参与当前构建。AXI 主端仍检查 RRESP/BRESP，将错误响应转换为访问异常。

## 接口边界与取舍

I/D 仲裁器最多保留一个读 burst，不按 ID 重排。路由器的读、写可以并行，
每个方向在事务期间保持同一个目标。AW/W 独立握手，不能要求地址和数据同拍到达。
最后一个 R 或 B 被消费时可以同拍接收下一地址。旧响应按寄存的来源/目标路由，
新地址独立选路；新 AR 被反压后继续锁定来源。五个通道分别驱动，避免无关字段的组合依赖。
CLINT 支持 AW/W 同拍接收，也支持先呈现 W、等待 AW 后再握手。
末 R/新 AR、旧 B/新 AW/W 可同拍交接，旧响应保持原事务身份；mtime 仍在 AR 握手时采样。
RV32 同宽转换不增加缓冲或流水级。

这一结构便于控制面积和追踪事务归属，代价是 I/D 读竞争共享带宽。
[访存说明](../microarchitecture/DCACHE_DESIGN_RECORD.md)解释缓存内的命中、缺失与维护；
[中断说明](../microarchitecture/TIMER_INTERRUPT_DESIGN_RECORD.md)解释 CLINT 与核的边界。

## 验证入口

`test-axi-handoff`、`test-core-merge`、`test-soc-width-converter`、`test-uncached` 与 `test-timer-interrupt`。
本轮结果见[周期优化验证](../verification/RV32_CYCLE_OPT_2026-09-19.md)。
[原设计记录](archive/AXI4_ARCHITECTURE_BEFORE_2026-09-16.md)保留供追溯。
