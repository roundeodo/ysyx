# CVA6 LSU 在途请求与本核差距

2026-10-01；源码评审，未运行 CVA6 仿真，也未实现新的 LSU。
本核为 interview 工作树，HEAD `5493a6aec976f4f9bdc075834d3f1202b0ae16ef` 加现有未提交改动；
当前后端与实测分别见[后端说明](../microarchitecture/BACKEND_DESIGN.md)和
[作用验证](../verification/RV32_RETIRE_BYPASS_2026-10-01.md)。不能只用 HEAD 复原本轮检查对象。

## 已核实的参考机制

参考 CVA6 **v5.3.0**，直接读取官方标签下源码；不把不同缓存配置当作同一种实现。

- [load_unit.sv](https://github.com/openhwgroup/cva6/blob/v5.3.0/core/load_unit.sv)：
  `NrLoadBufEntries` 项保存 scoreboard transaction ID、地址低位、load 操作。
  D-cache 请求握手时占用项，响应按 `data_rid` 找项并释放；请求和响应控制独立。
  `IDLE`、`SEND_TAG` 都能接收新请求，满足容量、地址相关、翻译和 cache grant 条件即可继续，
  不要求所有旧 load 完成。这里的 ID 是 cache 接口身份，不直接等于 AXI ID。
  flush 标记旧项为 flushed，迟到响应不能更新 scoreboard；尚未返回的项不会因 flush 立即复用。
- [load_store_unit.sv](https://github.com/openhwgroup/cva6/blob/v5.3.0/core/load_store_unit.sv)：
  LSU bypass 将入口接收与 load/store 单元推进连接起来；load 的 `pop_ld_o` 在请求获准时发生，
  load 结果另由 `load_valid_o` 返回。这是请求和完成解耦，不是等待返回才释放唯一入口。
- [store_buffer.sv](https://github.com/openhwgroup/cva6/blob/v5.3.0/core/store_buffer.sv)：
  区分 speculative queue 与 commit queue。地址/数据可以先入未提交队列；获 commit 授权后才进入
  已提交队列并向缓存写入。flush 清未提交项，已提交项继续排空。
  该版本按地址 `[11:3]` 做保守冲突检查；load 冲突时等待，没有在此处实现 store-to-load 数据转发。
  不应把这种地址局部比较照搬到本核的物理地址设计。

三个不同问题必须分别回答：LSU 可保存多少条在途 load、cache 是否允许 miss 期间继续 lookup、
下层有多少个未完成 refill。load buffer 深度、MSHR 数与 AXI ID/事务数不能混用。

| v5.3.0 配置或模块 | 已核对的能力与边界 |
| --- | --- |
| `cv32a6_imac_sv32_config_pkg.sv` | load buffer 2 项，选择 HPDCACHE_WT；不是所有 CVA6 配置的固定参数 |
| `cva6_hpdcache_subsystem.sv` | 上述参数推导 MSHR 为 1 set × 2 ways；接口按身份配对请求/响应 |
| `cv64a6_imafdc_sv39_config_pkg.sv` | load buffer 同样为 2 项，但选择传统 WT cache |
| `wt_dcache_ctrl.sv` | hit 路径允许交接；读端口进入 MISS_WAIT 后不再 grant 新读，等待该 miss 返回 |

配置与缓存来源：
[RV32 配置](https://github.com/openhwgroup/cva6/blob/v5.3.0/core/include/cv32a6_imac_sv32_config_pkg.sv)、
[HPDcache 集成](https://github.com/openhwgroup/cva6/blob/v5.3.0/core/cache_subsystem/cva6_hpdcache_subsystem.sv)、
[RV64 WT 配置](https://github.com/openhwgroup/cva6/blob/v5.3.0/core/include/cv64a6_imafdc_sv39_config_pkg.sv)、
[WT 读控制](https://github.com/openhwgroup/cva6/blob/v5.3.0/core/cache_subsystem/wt_dcache_ctrl.sv)。
[HPDcache 官方项目](https://github.com/openhwgroup/cv-hpdcache)明确支持每个请求方的多在途请求和
多个下层读写事务。这说明存在适用的非阻塞缓存实现，不保证任意请求组合都能无停顿并行。

## 本核阻塞在哪里

| 位置 | 当前事实 | 放开并发需要改变的内容 |
| --- | --- | --- |
| `riscv32_backend` | 单个 `lsu_tag_q`、pending/discard 状态 | 每个在途操作的完成身份、年龄及取消状态 |
| `riscv32_lsu` | 单个 pending context；仅空闲或旧成功响应交付当拍接收新请求 | 多项上下文与请求/响应独立控制 |
| `riscv32_data_mem` | 一个 route_state 保持到响应完成 | 多事务路由及响应归属；MMIO 仍需受序约束 |
| `riscv32_dcache` | `!miss_transaction_present` 限制新 lookup；仅一个 miss 上下文 | 若需 hit-under-miss，拆开 miss 占用与可用阵列端口；若需多 miss，再扩 MSHR/总线 |

当前连续 hit 已支持响应与下一请求同拍交接，不能把整条 LSU 描述成每次固定多等一拍。
但 `lw A; lw B; independent mul` 中，A 等待期间 B 发不出去，顺序派发也不能让 MUL 越过 B。
这与已经验证的 `lw A; independent mul` 能重叠，是两个不同能力。
仅增加 ROB 深度不会解除上述接收限制；仅增加 LSU 入口队列可能让 B 暂存后继续发 MUL，
但不会使 B 自动越过阻塞 D-cache，也不会自动缩短两次 miss 的总等待。

## 下一步应怎样验证和取舍

这些是候选，不是已实现或已测得收益：

1. 在同一 Total/Scored 窗口分别测量 RAW、第二条访存被拒绝、ROB 满、store 队首授权、
   cache hit/miss 的阻塞周期；区分重叠计数与互斥归因。已有跨 FU 重叠计数不能替代这些数据。
2. 先比较两项 load 上下文配合单 miss 的简单对照。空时直接发、反压才保存，检查是否仅解除
   顺序派发阻塞；用连续 hit、miss 后独立运算、miss 后另一条 hit、两个独立 miss 分开验证。
3. 若 miss 后 hit 的机会足够，再实现一个 miss 在途时继续处理无冲突 hit；记录回填/store/lookup
   的阵列端口争用。若主要是独立 miss，才比较两项 MSHR。新增下层并发还须核查仿真总线模型。
4. store buffer 独立评估。先存地址/数据与允许产生写副作用是不同事件；不能只放开 memory_safe。
   CVA6 此 store buffer 在 cache grant 时释放已提交项、不依赖 rvalid，不能照搬为本核的 AXI 错误策略。
   如提前退休 store，必须另定迟到错误处理；否则保留退休前错误确认协议。
5. 重点覆盖同地址/同 cacheline、store-load 字节重叠、随机反压、回包乱序、恢复与返回同拍、
   迟到响应及身份复用、MMIO、FENCE.I、clean 失败与 dirty-victim 恢复。
   若复制被替换脏行保护上下文，必须明确其生命周期和面积代价。

源码证明了当前限制，也证明 CVA6 存在更强的访存并发机制；尚未证明它是本核 MicroBench
整体负收益的主要来源。改动收益仍要由同镜像 RTL 周期、合法 STA 频点时间和面积决定。

本次读取的本核文件与官方标签源码 SHA-256 见[来源清单](data/cva6-lsu-review-20261001.json)。

## 实测补充

已完成原生MicroBench test窗口归因、等工作量指令调度对照及D-cache容量对照，见
[LSU阻塞实测](../verification/RV32_LSU_STALLS_2026-10-01.md)。单事务限制对部分程序确有影响，
但扩容后ROB仍未整体领先。多miss还受本核AXI读仲裁/路由单事务约束；后续优先比较
两项load上下文与单MSHR的hit-under-miss，不把有队列等同于下层读并发。

扩展到 HPDcache、Rocket、BOOM、CV32E40P 和 Ibex 的比较与升级候选，见
[LSU/D-cache 设计依据](LSU_DCACHE_DESIGN_REVIEW.md)。原两步作为对照，不代表最终架构。
