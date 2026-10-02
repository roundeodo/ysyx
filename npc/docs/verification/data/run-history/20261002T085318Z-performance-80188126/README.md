# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --direction-policy 0 --ras-entries 4 --branch-static 2 --early-target 1 --output npc/result/wait-opt-perf/current`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2637702, "retired_instructions": 831609, "ipc": 0.3152778441234074, "timer_ticks": 3768, "timer_seconds": 0.003768, "cycle_seconds": 0.0037681457142857144, "interrupts": 0}`
- scored: `{"cycles": 1021749, "retired_instructions": 430313, "ipc": 0.4211533360933067, "timer_ticks": 1461, "timer_seconds": 0.001461, "cycle_seconds": 0.0014596414285714286, "interrupts": 0}`
