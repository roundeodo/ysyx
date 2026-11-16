# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale train --timing-model device-clock --cpu-mhz 700 --execute-result-registered 0 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --direction-policy 0 --history-bits 4 --ras-entries 4 --branch-static 2 --early-target 1`

- scale: `"train"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 633735042, "retired_instructions": 266934954, "ipc": 0.42120907999277085, "timer_ticks": 905335, "timer_seconds": 0.905335, "cycle_seconds": 0.9053357742857143, "interrupts": 0}`
- scored: `{"cycles": 514264228, "retired_instructions": 186810327, "ipc": 0.36325747899385297, "timer_ticks": 734667, "timer_seconds": 0.734667, "cycle_seconds": 0.7346631828571428, "interrupts": 0}`
