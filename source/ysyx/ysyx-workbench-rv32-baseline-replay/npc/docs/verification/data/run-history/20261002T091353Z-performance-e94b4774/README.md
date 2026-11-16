# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --direction-policy 0 --ras-entries 4 --branch-static 2 --early-target 1 --output npc/result/wait-opt-perf/current`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2684048, "retired_instructions": 831627, "ipc": 0.3098405840730121, "timer_ticks": 3835, "timer_seconds": 0.003835, "cycle_seconds": 0.003834354285714286, "interrupts": 0}`
- scored: `{"cycles": 1048002, "retired_instructions": 430313, "ipc": 0.4106032240396488, "timer_ticks": 1496, "timer_seconds": 0.001496, "cycle_seconds": 0.0014971457142857142, "interrupts": 0}`
