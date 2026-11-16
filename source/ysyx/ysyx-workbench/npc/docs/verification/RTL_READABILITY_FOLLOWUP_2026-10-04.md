# RV64 前端、访存与系统接口可读性复核

接续[第一轮](RTL_READABILITY_2026-10-04.md)，检查前端、缓存、LSU、CSR 和系统互连。
本轮只修正命名、注释和完整代码块的位置，保留组合表达式、过程内语句顺序、寄存边界、
复位及握手条件。不更改算法、旁路、缓存配置或设备模型。

## 修改前发现与处理范围

- CSR 的 `csr_read_illegal` 同时报告非法读和非法写，改用 `csr_access_illegal`。
- LSU 的 `active_lsu_req` 是即将发出或重试的请求，不一定是正在等待响应的旧请求，
  改为 `dispatch_lsu_req`；请求侧条件、store 格式与返回 load 格式分别成组。
- 位宽转换器的 `write_last_data_forwarded_q` 在本地错误路径丢弃 WLAST 后也置位，
  改为描述写数据阶段完成，不声称数据已经转发，也不表示 B 响应完成。
- BTB 的替换路数组与下一路编号补齐 `index`；I-cache 替换逻辑明确 RRPV 老化增量的含义。
- 数据存储路由器先呈现请求分流和两个子模块，再呈现响应与 AXI 汇合；位宽转换器的
  写握手与进度条件移到写通路，读错误拍计数更新移到读状态更新区。
- I-cache 数据阵列的读输出映射放在读寄存器更新之前；替换候选组合选择与状态更新分开。

## 检查结论与边界

本轮修改 9 个 RTL 文件及 1 个端口连接测试。IFU、RAS、D-cache、AXI 仲裁器和
地址路由器也进行了组织检查；其现有功能分组能够表达事务归属和数据流，本轮没有重排。
CSR 的异常、mret、普通写入优先级仍集中在原有时序过程内。

代码的阅读顺序表达输入、选择、计算、输出和反馈关系，不表示 SystemVerilog 模块
按文件中的先后位置串行执行。相关条件和非空 case 分支的赋值分行书写。
本轮检查不能替代形式等价、全功能验证或时序签核。

## 验证

以下命令退出码为 0：

```sh
make git_commit= test-lsu test-privileged test-soc-width-converter \
  test-dcache test-icache test-icache-replacement test-pipeline lint
```

- LSU、CSR/提交/PMU、AXI 64→32 位宽转换、D-cache、I-cache 和流水控制测试通过。
- I-cache 替换策略检查 24,750 次决策，覆盖失效、前递和快照保持。
- 取指队列检查 1,012 次输出、746 次同时进出和 34 次冲刷。
- 对 10 个文件进行重命名归一后的标记计数及完整过程体比较，全部通过。
  最后的分行排版未改变这些标记及过程内顺序。这是源码结构检查，不是形式等价证明。
- 完整 SoC lint 前后均成功退出，警告类别、数量和按文件归一后的诊断一致。
  原有 9 项 UNOPTFLAT 等警告仍存在，本轮没有解决或新增这些诊断。
- `git diff --check` 通过。未运行 train、完整 SoC 程序或综合时序。

保留第一轮证据。本轮的独立差异、源码哈希、lint 比较和验证摘要位于
[data/rtl-readability-followup-2026-10-04](data/rtl-readability-followup-2026-10-04/)。

