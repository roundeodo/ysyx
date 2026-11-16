# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --direction-policy 0 --ras-entries 4 --branch-static 2 --early-target 1 --output npc/result/wait-opt-perf/current`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2684531, "retired_instructions": 831627, "ipc": 0.3097848376494814, "timer_ticks": 3835, "timer_seconds": 0.003835, "cycle_seconds": 0.0038350442857142857, "interrupts": 0}`
- scored: `{"cycles": 1048317, "retired_instructions": 430313, "ipc": 0.41047984531396514, "timer_ticks": 1497, "timer_seconds": 0.001497, "cycle_seconds": 0.0014975957142857143, "interrupts": 0}`
