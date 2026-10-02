# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 715 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --direction-policy 0 --ras-entries 4 --branch-static 2 --early-target 1 --output npc/result/wait-opt-perf/current`

- scale: `"test"`
- cpu_mhz: `715`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2722008, "retired_instructions": 831627, "ipc": 0.30551967518096934, "timer_ticks": 3807, "timer_seconds": 0.003807, "cycle_seconds": 0.003807004195804196, "interrupts": 0}`
- scored: `{"cycles": 1058603, "retired_instructions": 430313, "ipc": 0.4064913853446476, "timer_ticks": 1479, "timer_seconds": 0.001479, "cycle_seconds": 0.0014805636363636363, "interrupts": 0}`
