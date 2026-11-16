# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --timing-model device-clock --predictor-enable 0 --dcache-enable 0 --icache-bytes 1024 --icache-ways 1 --icache-line 16 --icache-policy 0 --branch-static 0 --early-target 0 --verify-observer --output npc/result/performance/replay-icache1k-no-predictor-test`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 5009725, "retired_instructions": 802050, "ipc": 0.1600986082070373, "timer_ticks": 7156, "timer_seconds": 0.007156, "cycle_seconds": 0.00715675, "interrupts": 0}`
- scored: `{"cycles": 2747871, "retired_instructions": 430307, "ipc": 0.15659650689570218, "timer_ticks": 3923, "timer_seconds": 0.003923, "cycle_seconds": 0.00392553, "interrupts": 0}`
