# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --bht-entries 16 --btb-entries 16 --btb-ways 2 --ras-entries 4 --direction-policy 5 --branch-sc 1 --branch-loop 1 --verify-observer --keep-artifacts --output npc/result/branch-v3/native-NSL-victim-700`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2669313, "retired_instructions": 831441, "ipc": 0.31148126877589855, "timer_ticks": 3814, "timer_seconds": 0.003814, "cycle_seconds": 0.0038133042857142856, "interrupts": 0}`
- scored: `{"cycles": 1058109, "retired_instructions": 430313, "ipc": 0.40668116422788203, "timer_ticks": 1509, "timer_seconds": 0.001509, "cycle_seconds": 0.0015115842857142856, "interrupts": 0}`
