# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --timing-model device-clock --predictor-enable 1 --dcache-enable 0 --icache-bytes 256 --icache-ways 1 --icache-line 16 --icache-policy 0 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --direction-policy 0 --ras-entries 4 --branch-static 2 --early-target 1 --verify-observer --output npc/result/performance/replay-hybrid-test`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 5698637, "retired_instructions": 822246, "ipc": 0.14428818680677502, "timer_ticks": 8141, "timer_seconds": 0.008141, "cycle_seconds": 0.00814091, "interrupts": 0}`
- scored: `{"cycles": 3102444, "retired_instructions": 430311, "ipc": 0.13870065019707045, "timer_ticks": 4432, "timer_seconds": 0.004432, "cycle_seconds": 0.004432062857142857, "interrupts": 0}`
