# 并行取指证据索引

从仓库根目录执行；基线为`05c2e63a37e2b379b74fc8a785b5e51566f30daf`。
本目录不含仿真器、综合网表或编译对象。

- `baseline.json`、`baseline-source.tar.gz`：修改前工作区状态与RV32源码。
- `baseline/`、`candidate/`：同镜像、同配置性能报告和完整测量manifest。
- `final.json`：结论、配置一致性检查、周期/面积/四组时序及源码哈希。
- `final/`：最终并行版本700 MHz报告、cell统计和综合命令。
- `first-parallel/`、`paired-response/`、`rrip-mask/`：三次未通过700 MHz的候选。
- `decode-compare-initial/`、`decode-compare/`：早期和最终并行底座上的必要ID比较路径实验。
  完整ID重定向未实现，均不是默认RTL。
- `contracts/`、`rrip/`、`small-replacement/`、`nemu/`、`logs/`：测试命令、哈希及日志。
- `observers/`、`observer-results.json`：两套研究观察器的30次软件检查；其内存模型与SoC性能测量不同。
- `final-tracked.patch`、`new-sources.tar.gz`：在冻结基线上重建修改所需的补丁和新增源码。
- `cleanup.json`：本轮删除的自有大型生成目录；报告和源码保留。

默认并行版本的主要复现命令：

```bash
NPC_HOME="$PWD/npc" make -C npc git_commit= NPC_CONFIG=rv32-balanced \
  test-parallel-fetch test-fetch test-pipeline test-fence-i test-precise-exception
python3 npc/scripts/test_selection_replacement.py \
  --policies 13 14 15 16 --output npc/result/parallel-fetch-rrip-replay
python3 npc/scripts/test_ex_merge_difftest.py \
  --registered 0 --output npc/result/parallel-fetch-difftest
python3 npc/scripts/run_microbench_perf.py \
  --scale test --timing-model device-clock --cpu-mhz 700 \
  --execute-result-registered 0 \
  --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 \
  --branch-static 2 --early-target 1 --verify-observer
python3 npc/scripts/run_synthesis.py --target sta-reset --keep-artifacts \
  NPC_CONFIG=rv32-balanced NPC_EXECUTE_RESULT_REGISTERED=0 \
  STA_FREQUENCY_MHZ=820 'STA_SYNTH_STRATEGY=AREA 3' \
  STA_TOOL_DIR="$PWD/npc/result/sta/rv32-interrupt-20260906/toolflow"
python3 npc/scripts/check_ex_merge_timing.py \
  --directory npc/result/synthesis/current/sta/riscv32_core_reset_boundary-820MHz-buffered \
  --toolflow npc/result/sta/rv32-interrupt-20260906/toolflow --mhz 700
```

`--keep-artifacts`只为随后加载700 MHz约束；读取报告后按产物规则清理大目录。
RRIP测试入口要求输出目录尚不存在。基线性能须在独立源码副本上重放，不能反向覆盖当前工作区。
