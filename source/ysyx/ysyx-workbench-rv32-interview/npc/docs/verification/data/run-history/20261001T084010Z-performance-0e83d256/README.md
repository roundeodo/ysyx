# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 720 --timing-model device-clock --verify-observer --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --direction-policy 0 --history-bits 4 --ras-entries 4`

- scale: `"test"`
- cpu_mhz: `720`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2774833, "retired_instructions": 831978, "ipc": 0.2998299357114464, "timer_ticks": 3854, "timer_seconds": 0.003854, "cycle_seconds": 0.0038539347222222224, "interrupts": 0}`
- scored: `{"cycles": 1088342, "retired_instructions": 430313, "ipc": 0.3953839877538494, "timer_ticks": 1512, "timer_seconds": 0.001512, "cycle_seconds": 0.001511586111111111, "interrupts": 0}`
