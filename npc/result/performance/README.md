# NPC性能评估结果

在`npc/`目录运行`make perf-record`可向表格追加一行。该命令记录MicroBench的PMU
测量窗口，不包含仿真器启动和退出周期。

表格中的commit用于标识被测源码树。工作流程是先提交源码修改，再记录性能结果，最后
用单独一次commit提交表格。仿真器原始日志保存在`result/performance/logs/`并被Git忽略。

使用明确测量的综合频率记录结果：

```sh
make perf-record \
  PERF_DESCRIPTION="baseline before cache" \
  PERF_FREQUENCY_MHZ=296.552
```

也可以从指定STA报告中提取限制性最大路径频率：

```sh
make perf-record \
  PERF_DESCRIPTION="baseline before cache" \
  PERF_STA_REPORT=result/<design>/<design>.rpt
```

`PERF_SCALE`默认为`train`。`PERF_SCALE=test`适合本地调试，但不能替代正式`train`结果。

2026-09-06 计时审计：`PERF_FREQUENCY_MHZ` 只填写结果，不能配置硬件定时器或设备延迟。
新测量应另传 `NPC_SIM_CPU_FREQ_MHZ=820`（或本次实际采用的 CPU 频率），同时配置
CLINT 和 CPU/100 MHz 外设的延迟比例。留空只用于复现旧环境：CLINT 按 100 MHz
换算，而延迟比例为 3037/1024。该旧环境的 Scored time 不能直接视为对应 STA 主频的
执行时间。详见 [计时规则](../../docs/verification/MICROBENCH_TIMING_RULES.md)。

| 日期（UTC） | NPC commit | AM-kernels commit | 规模 | 说明 | 仿真周期数 | 退休指令数 | IPC | 综合频率（MHz） |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: |
<!-- PERFORMANCE_RESULTS:INSERT_BEFORE -->
