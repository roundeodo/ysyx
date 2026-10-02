# RV32 分支预测 V3 实验入口

这轮固定RV32I单发射后端、I$1KiB/4路/32B、D$256B/2路/16B，比较完整的方向＋目标＋预测时机。2026-10-02已确认将H2E均衡方案用于`rv32-balanced`：弱态BTFNT、早期直接目标、700 MHz；其他新机制保持显式实验开关。仅本地提交，不推送或合并。

先看[选型结论](decision.md)：已完成三类RTL、BTB联合比较和冻结后的保留集测量。
全部方案的测试层次及35点开发矩阵见[实验总表](experiment-summary.md)。
后续四类目标获取方法的54组开发集模型准确率见[模型补测](target-model-study.md)，不属于上述35点RTL/PPA矩阵。
BTB替换扩展为14种策略、420组模型配置，另有同组织SRRIP/SHiP式RTL对照，见[替换策略补测](btb-replacement-study.md)。
短/长保留组分开报告，原始参数和频点不因保留结果改变。诊断阶段结束、尚未实现的机制明确列在`coverage.json`。
按问题查[执行计划](plan.md)、[实验空间](design-space.md)、[候选研究卡](candidate-contracts.md)、
[文献与实际借鉴](literature.md)、[验证边界](verification.md)、[负载与收益归因](attribution.md)。
RTL逐级结构见[电路契约](../../microarchitecture/BRANCH_V3_DESIGN.md)，实际事件例子见[查询到提交](query-walkthrough.md)。

## 重建而不覆盖现有证据

以下命令从仓库根目录执行。已有`result/branch-v3`时，应用另一独立checkout进行完整重建；脚本对已存在的原始运行目录报错，避免静默覆盖。无需删除当前关键证据。依赖版本与原始命令/哈希分别在baseline_manifest、输入manifest、build manifest和evidence-index中。

先按仓库依赖流程准备RV32子模块补丁、RISC-V GCC、Verilator、NEMU和capstone；当前am-kernels/ysyxSoC的本地修改是已冻结依赖，不要清掉。STA需要现有Nangate45工具包；可用`NPC_STA_TOOLFLOW=/绝对路径/toolflow`指定，不应换库或综合策略再直接比较。

```bash
python3 npc/scripts/build_branch_workloads.py \
  --output npc/result/branch-v3/images \
  --dev-seeds 2411 2418 --held-seeds 2437 2442
python3 npc/tools/branch_v3/fetch_author.py
python3 npc/tools/branch_v3/fetch_inputs.py
python3 npc/tools/branch_v3/build_upstream.py
python3 npc/tools/branch_v3/build_streams.py --split development
python3 npc/tools/branch_v3/build_streams.py --split validation

python3 npc/tools/branch_v3/run_core.py build --name B0-final-off
python3 npc/tools/branch_v3/run_core.py run --name B0-final-off
python3 npc/tools/branch_v3/run_candidates.py H2E-narrow R0-held NSmallER-held N0 NL NS NSL
```

第一次冻结的B0、B0off、N0等历史标签对应各自源码快照；重建当前源码时必须核对快照差异，不能因为名字相同就认为二进制完全相同。当前接口型式允许用`--name`给独立运行明确命名；`--label`仅命名运行目录，不改变硬件。

```bash
python3 -m unittest discover -s npc/tests/branch_v3 -p 'test_models.py'
python3 npc/tools/branch_v3/check_tage_scl.py
python3 npc/tools/branch_v3/check_spec_history.py
python3 npc/tools/branch_v3/check_geometry.py
python3 npc/tools/branch_v3/check_directed.py
python3 npc/tools/branch_v3/run_safety.py R0-held NSmallER-held H2E-narrow
python3 npc/tools/branch_v3/run_difftest.py R0-held NSmallER-held H2E-narrow
python3 npc/tools/branch_v3/run_ppa_candidates.py H2E-narrow R0-held NSmallER
python3 npc/tools/branch_v3/run_qualified_matrix.py H2E-narrow R0-held NSmallER --common-mhz 400
python3 npc/tools/branch_v3/summarize.py --paths
```

完整的原始命令优先取各次manifest；`check_early.py`、`check_formal.py`、`mutation_check.py`等其他驱动的参数见`--help`或对应记录。显式PPA名`NSmallER`与修复后仿真名`NSmallER-held`绑定，不使用前一版未保持RAS返回载荷的结果。

## 原生SoC参照

```bash
python3 npc/scripts/run_microbench_perf.py \
  --scale test --cpu-mhz 700 \
  --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 \
  --branch-static 2 --early-target 1 --verify-observer \
  --output npc/result/branch-v3/native-H2E-recheck
```

这是H2混合＋早期直接目标。新TAGE用`--direction-policy 5`；SC、loop分别用`--branch-sc`、`--branch-loop`，默认0。推测历史目前禁止与局部early override组合，不能忽略配置保护强行全开。原生SoC与独立物理ns测试台必须分别比较；测试台早期配置为128KiB RAM，最终五种候选统一为2MiB。

最终保留集只能在selection-freeze.json已写入、候选二进制与允许频率匹配后用`run_core.py --final`运行；开发和验证命令不能绕过这项检查。保留集失败可以否决候选，不能继续拿它选参数。

BTB容量、索引、准入与替换的追加实测见[BTB联合探索](btb-study.md)；长请求输入划分与限制见[工作负载来源](workload-provenance.md)。

## BTB追加实验与结果复核

`btb-matrix.json`、`btb-joint-matrix.json`及`btb-*-extension.json`记录单项与联合配置。
`screen_btb.py`做120点固定事件筛选，`test_btb.py`独立检查表状态，
`run_btb_matrix.py`/`run_btb_extended.py`运行显式配置，`probe_ppa.py`只复核已映射网表的指定频点。
`complete_btb_measurements.py`补同频、验证与延迟敏感性；`run_large_btb_matrix.py`运行预定长输入；
`check_btb_layouts.py`检查两种整体代码偏移。完整原始命令、镜像、源码和工具身份以manifest为准。

当前目录已有证据时，下面只复核、汇总，不重复运行应用：

```bash
python3 npc/tools/branch_v3/check_paired_windows.py
python3 npc/tools/branch_v3/summarize_final.py
python3 npc/tools/branch_v3/summarize_prediction_counts.py
python3 npc/tools/branch_v3/audit_ppa_sources.py
python3 npc/tools/branch_v3/write_decision.py
python3 npc/tools/branch_v3/index_evidence.py
```

保留执行由`freeze_selection.py`和`run_final.py`控制。首次冻结前要求35点PPA/同频、
10点短验证、7点长开发/验证、安全与实际事件模型比对全部存在；已冻结的角色不能重新选参。
`final-platform-check.json`与`final-source-check.json`核对最终五个仿真器的统一配置及交付RTL。
`ppa-delivery-audit.json`核对五种配置的综合输入与交付RTL；早期H2E按原流程重映射，
确认网表、SDC、面积和700MHz时序均与冻结结果相同，没有重新选参。
`final-prediction-counts.json`从冻结日志分开统计方向错误与EX纠错，口径见[预测错误统计](prediction-counts.md)。

新BTB原生入口增加`--btb-index 0/1/2`、`--btb-admission 0/1/2`。
改进32项组织为`--btb-entries 32 --btb-ways 4 --btb-policy 2 --btb-index 2 --btb-admission 2`。
当前compact目标不能和新索引/准入混用，命令行与RTL均拒绝该未验证组合。

## 四类目标方法的准确率重放

以下重放固定基线实际查询、解析和I$安装时刻；四类新模型不改变RTL默认值。
需要已有`B0-victim-dev`、`B0-victim-stream-dev-700`的原始事件，以及新记录的旁观I$元数据。
已有记录时直接运行后三条命令；不重复构建、覆盖原始运行目录。

```bash
python3 npc/tools/branch_v3/run_core.py build --name B0-target-model-20261002
python3 npc/tools/branch_v3/run_core.py run \
  --name B0-target-model-20261002 --label B0-target-model-20261002-dev \
  --compact --metadata-trace
python3 npc/tools/branch_v3/run_core.py run \
  --name B0-target-model-20261002 --label B0-target-model-20261002-streams \
  --images npc/result/branch-v3/streams-development --compact --metadata-trace

python3 -m unittest discover -s npc/tests/branch_v3 -p 'test_target_models.py' -v
python3 npc/tools/branch_v3/run_target_accuracy.py --workers 2
python3 npc/tools/branch_v3/summarize_target_accuracy.py
```

18种目标组织与BHT16、缩放TAGE、缩放TAGE＋SC＋Loop分别组合，共54点/14开发输入。
旁观记录的完整运行命令、工具与源码见构建/运行manifest，输入及事件哈希见`target-accuracy-models.json`。
模型不再生候选自己的错误路径/缓存驻留，不能把准确率直接换算为周期、IPC或面积×时间。
`--case`只用于单输入调试，会产生局部报告；正式汇总要求完整14输入，不以调试结果代替最终表。

大事件和综合中间JSON只做校验后的无损压缩；完全相同的频点网表共享只读存储，
不要原地修改其中某个副本。只移除已链接构建的可再生对象，源码、输入、可执行文件、报告及失败证据保留。

## BTB替换策略扩展

模型使用上一节冻结的实际Q/F/C和cache安装事件。契约`btb-replacement-contract.json`先于实验固定参数；
模型只筛选准确率，不将回放事件当成候选自己的CPU执行。派生二进制输入无损压缩并校验，原事件不删除。

```bash
g++ -std=c++17 -O2 -Wall -Wextra -Werror -I npc/tools/branch_v3 \
  npc/tests/branch_v3/replacement_tb.cpp -o /tmp/branch-v3-replacement-test
/tmp/branch-v3-replacement-test
python3 npc/tools/branch_v3/run_replacement_study.py --workers 2
python3 npc/tools/branch_v3/summarize_replacement_study.py
```

从另一独立checkout重建追加RTL证据；已有目录时不覆盖：

```bash
python3 npc/tools/branch_v3/test_btb.py \
  --output npc/result/branch-v3/btb-unit-replacement
python3 npc/tools/branch_v3/run_btb_extended.py rtl \
  NSL-BT16-RRIP-replacement NSL-BT16-SHiP-replacement \
  --matrix npc/docs/research/branch-v3/btb-replacement-rtl-matrix.json
python3 npc/tools/branch_v3/run_safety.py NSL-BT16-SHiP-replacement
python3 npc/tools/branch_v3/run_difftest.py NSL-BT16-SHiP-replacement
python3 npc/tools/branch_v3/run_btb_extended.py ppa \
  NSL-BT16-RRIP-replacement NSL-BT16-SHiP-replacement \
  --matrix npc/docs/research/branch-v3/btb-replacement-rtl-matrix.json
```

policy4只用于完整目标BTB原型；compact联合策略仍停留在模型，未改原生MicroBench入口。
方向、容量、路数、索引、准入和cache保持相同，唯一硬件差别是签名插入学习。
追加测量不替换`selection-freeze.json`或`final-results.json`的候选与结果。

共同合法频率取两种配置STA通过频点的较小值；在该频率和各自通过频率分别重跑两个配置。
例如本轮共同频率660MHz，用`run_btb_extended.py frequency <配置名> --matrix <上面的矩阵> --mhz 660`。
`probe_ppa.py <较快配置名> --mhz 660`只在相同冻结网表上核查共同频率，不重新映射。
测量完整后运行`summarize_replacement_rtl.py`和`index_evidence.py`；
[RTL结果说明](btb-replacement-rtl-study.md)把700MHz分析运行与真正通过的频率分开。
