# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --early-ras 1 --host-opt 1 --verify-observer --keep-artifacts --output npc/result/branch-v3/native-R0-held`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2716073, "retired_instructions": 831897, "ipc": 0.30628668669803794, "timer_ticks": 3881, "timer_seconds": 0.003881, "cycle_seconds": 0.0038801042857142857, "interrupts": 0}`
- scored: `{"cycles": 1069821, "retired_instructions": 430313, "ipc": 0.4022289710147772, "timer_ticks": 1529, "timer_seconds": 0.001529, "cycle_seconds": 0.0015283157142857143, "interrupts": 0}`
