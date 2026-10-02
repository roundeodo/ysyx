# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --direction-policy 0 --ras-entries 4 --branch-static 2 --early-target 1 --output npc/result/wait-opt-perf/current`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2643463, "retired_instructions": 831609, "ipc": 0.31459074706171414, "timer_ticks": 3776, "timer_seconds": 0.003776, "cycle_seconds": 0.003776375714285714, "interrupts": 0}`
- scored: `{"cycles": 1026060, "retired_instructions": 430313, "ipc": 0.41938385669454026, "timer_ticks": 1466, "timer_seconds": 0.001466, "cycle_seconds": 0.0014658, "interrupts": 0}`
