# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --timing-model device-clock --cpu-mhz 700 --execute-result-registered 0 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --branch-static 2 --early-target 1 --verify-observer --output npc/result/performance/parallel-fetch-final`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2618725, "retired_instructions": 832008, "ipc": 0.31771491851950856, "timer_ticks": 3741, "timer_seconds": 0.003741, "cycle_seconds": 0.003741035714285714, "interrupts": 0}`
- scored: `{"cycles": 1020490, "retired_instructions": 430313, "ipc": 0.4216729218316691, "timer_ticks": 1459, "timer_seconds": 0.001459, "cycle_seconds": 0.0014578428571428571, "interrupts": 0}`
