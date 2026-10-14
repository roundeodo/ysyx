# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --timing-model device-clock --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --branch-static 2 --early-target 1 --verify-observer --output npc/result/performance/ex-merge-candidate`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2670300, "retired_instructions": 831573, "ipc": 0.3114155712841254, "timer_ticks": 3815, "timer_seconds": 0.003815, "cycle_seconds": 0.003814714285714286, "interrupts": 0}`
- scored: `{"cycles": 1048867, "retired_instructions": 430313, "ipc": 0.4102645998015001, "timer_ticks": 1499, "timer_seconds": 0.001499, "cycle_seconds": 0.0014983814285714286, "interrupts": 0}`
