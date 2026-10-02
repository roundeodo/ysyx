# 一条查询如何产生并兑现预测

原始证据：`result/branch-v3/rtl/NSmallER-held/ini_config-dev-2411.events`，动态ID **2336**。参数是base16、两张8项tagged表、tag6bit、history3/7，SC与loop关闭、解析历史，early B/J与RAS开启。

| CPU周期 | 实际事件 | 含义 |
| --- | --- | --- |
| 10192 | Q：PC=0x800001c0，epoch=2，BTB miss，raw_taken=1 | 方向已预测taken，但请求侧没有目标，暂按顺序取指。没有读取未来分支结果 |
| 10194 | A：当前指令交付，taken=1，target=0x800001a4 | 指令返回后识别条件分支，由PC+符号扩展立即数算出精确目标，采用原查询方向 |
| 10194 | E：early redirect到0x800001a4 | 与交付同拍，保留当前及更老指令；仅清年轻查询，已展示的旧总线请求仍排空 |
| 10196 | R：actual_taken=1，actual_target=0x800001a4，late_redirect=0 | EX结果被接收，按原查询context训练；早期纠正正确，不再产生EX PC恢复 |
| 10197 | C：提交fef812e3，next_PC=0x800001a4 | 实际退休证实该次方向和目标。动态ID贯穿Q/A/R/C，不靠PC猜测是否同一实例 |

查询context容器的十六进制值为`0000000000000000000000020000070000024f3c0fb60039`。按105bit有效布局解码，具体字段见下方；epoch是预测器失效代数，与Q中的前端epoch不是同一个字段。解析历史版本不需要保存完整history_before，该字段为0，不能把它解释为查询时GHR本身为0。

```json
{
  "prediction": 1,
  "loop_index": 0,
  "sum": 7,
  "sc_indices": 352,
  "tage": 1,
  "weak": 0,
  "raw": 1,
  "alternate": 1,
  "provider": -1,
  "base_index": 0,
  "tags": 3900,
  "indices": 36,
  "epoch": 0,
  "pc": 2147484096,
  "history_before": 0
}
```

这条记录说明BTB miss会屏蔽已正确的方向输出，早期直接目标让方向得以被采用。但10194至10196的两拍并不自动等于整核净省两拍；队列、缓存和共享总线可能重叠或改变后续等待，净收益仍取实际闭环周期差。
