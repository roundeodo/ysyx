# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 550 --timing-model device-clock --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --branch-static 2 --early-target 1 --execute-result-registered 0 --output npc/result/performance/ex-merge-550`

- scale: `"test"`
- cpu_mhz: `550`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2320204, "retired_instructions": 831036, "ipc": 0.35817367783177684, "timer_ticks": 4219, "timer_seconds": 0.004219, "cycle_seconds": 0.004218552727272728, "interrupts": 0}`
- scored: `{"cycles": 947507, "retired_instructions": 430313, "ipc": 0.4541528453087946, "timer_ticks": 1722, "timer_seconds": 0.001722, "cycle_seconds": 0.00172274, "interrupts": 0}`
