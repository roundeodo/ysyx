# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --timing-model device-clock --icache-bytes 256 --icache-ways 1 --icache-line 16 --icache-policy 0 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --direction-policy 0 --branch-static 0 --early-target 0 --ras-entries 4 --verify-observer --output npc/result/performance/replay-test`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 4354861, "retired_instructions": 821436, "ipc": 0.1886250789634847, "timer_ticks": 6221, "timer_seconds": 0.006221, "cycle_seconds": 0.00622123, "interrupts": 0}`
- scored: `{"cycles": 1764863, "retired_instructions": 430311, "ipc": 0.24382119178655795, "timer_ticks": 2519, "timer_seconds": 0.002519, "cycle_seconds": 0.002521232857142857, "interrupts": 0}`
