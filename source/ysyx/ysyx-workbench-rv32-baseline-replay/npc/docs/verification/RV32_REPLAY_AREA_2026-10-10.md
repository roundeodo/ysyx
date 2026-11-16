# Replay：关闭预测及映射面积分解

> 历史配置与测量记录。2026-10-11 replay 默认已接入正式混合预测；当前配置和启动命令见
> [接入记录](RV32_REPLAY_HYBRID_2026-10-11.md)。本文旧面积不代表新组合。

仅作用于 `ysyx-workbench-rv32-baseline-replay`，interview RTL/配置未修改。
RV32I顺序单发射，I-cache256 B/单路/16 B；无D-cache；前递保留。
复现上轮原始有预测硬件，含复位缓冲整核面积 **47692.204 µm²**，逐单元相加与Yosys统计一致。
关闭BHT16、BTB16/2路、RAS4后为 **36505.840 µm²**，减少11186.364 µm²（23.4553%）。
NanGate45、AREA 3、820 MHz映射目标；是标准单元映射面积，不是布局布线面积。
无预测配置在820 MHz的setup/hold/gating四类检查通过，不将单次频点称为最高频率。

## 47692.204 µm² 配置的分布

按综合网表的单元实例名及经过RTL连接核对的输出信号名，分配到功能区。
展平优化后部分寄存器改用顶层信号名，不能只靠子模块前缀统计。
这是整核映射后的逻辑归属，跨模块共享优化可能影响归属；不是分别综合模块所得的独立面积。
每个单元只统计一次，未明确归属部分单列。分类规则与逐单元原始记录全部保存。

| 功能区 | 面积 µm² | 占比 |
| --- | ---: | ---: |
| I-cache、回填与取指AXI | 13731.452 | 28.79% |
| 预测器与预测响应 | 9016.868 | 18.91% |
| 整数寄存器堆 | 7393.736 | 15.50% |
| 译码、操作数选择/前递与ID/EX | 4775.764 | 10.01% |
| IFU与fetch buffer | 3005.800 | 6.30% |
| 执行、分支解析与EX结果级 | 2766.666 | 5.80% |
| CSR与PMU计数器 | 2519.020 | 5.28% |
| LSU与uncached访存 | 2063.894 | 4.33% |
| 完成选择、WB与提交 | 1923.712 | 4.03% |
| 冒险、恢复、异常/中断及FENCE.I | 354.312 | 0.74% |
| 共享逻辑、复位与未明确归属 | 140.980 | 0.30% |

预测器原实例名内：BTB7234.136、BHT306.964、RAS872.480 µm²；这些子项属于上表预测功能区，
不可再相加到总面积。另有查询响应PC/epoch/预测字段及选择逻辑。
I-cache数据阵列9146.410、tag阵列2479.120 µm²（含各自映射读写逻辑）。
这些阵列被映射为标准单元，并非SRAM宏面积。

## 关闭预测的电路变化

构建参数 `NPC_BRANCH_PREDICTOR_ENABLE=0`，package统一定义使能，branch_predictor的generate
不实例化BHT/BTB/RAS，预测元数据恒零。保留现有PC/epoch/valid响应寄存级和原握手、flush协议，
不新增流水级。前端按PC+4，实际控制转移仍由EX解析与恢复。
所谓无预测，是没有预测表、动态训练和提前taken预测，顺序取指仍隐含采用not-taken路径。
不删除历史模块或正确性断言。打开参数可恢复原表；当前版本因新增开关而不再是逐字原始RTL。

移除预测带来的11186.364 µm²大于表和选择逻辑的原实例面积8416.772 µm²：
预测元数据为常量以后，请求队列、流水payload和比较/选择逻辑进一步缩减。
因此原配置模块占比与关闭模块后的整核差值是两个不同指标。

## 验证与复现

无预测lint通过；独立PC/epoch握手参考测试12000拍：7726次请求、1487拍响应反压、169次flush，
两次中途复位，持续注入taken JAL训练，检查预测元数据始终零、next-PC为PC+4、响应不丢不重不换身份。
原生MicroBench test通过：700 MHz，device-clock-v1，Total9.693 ms/IPC0.118193425，
Scored5.146 ms/IPC0.119476803。未运行train，未新增DiffTest测量。

Replay Makefile和性能脚本默认现在均为无D-cache、无预测。原先prepare-only的模拟器不随默认值改变。
新的train（未运行）：

```bash
cd /home/yong/ysyx/ysyx-workbench-rv32-baseline-replay
python3 npc/scripts/run_microbench_perf.py --scale train --cpu-mhz 700 \
  --dcache-enable 0 --predictor-enable 0 \
  --output npc/result/performance/replay-no-predictor-train
```

只恢复预测用 `--predictor-enable 1`；恢复原D-cache另加 `--dcache-enable 1`。
综合复现用run_synthesis.py，显式传 `NPC_BRANCH_PREDICTOR_ENABLE=0`，其他参数同前一日记录。
原47692.204分解来自新增开关前的冻结源；对应配置快照和原始综合网表压缩归档保存。
原始RTL来源仍为e3b018f；新开关改动以补丁保存。

证据：`data/baseline-replay-20261009/area-grouping.json`、`area-with-predictor.json`、
`area-without-predictor.json`、`predictor-ab.json`；run-history包含综合原统计与四类STA报告。
`mapped_area_breakdown.py`按Liberty cell area统计，并与Yosys面积逐数核对。
综合及仿真大编译产物清理，保留分析、单元归属和小型原始网表压缩件。
