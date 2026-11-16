# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale train --cpu-mhz 700 --timing-model device-clock --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --btb-index 0 --btb-admission 0 --direction-policy 0 --history-bits 4 --ras-entries 4 --branch-static 2 --early-target 1 --early-ras 0 --branch-sc 0 --branch-loop 0 --spec-history 0`

- scale: `"train"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 641446522, "retired_instructions": 266934982, "ipc": 0.416145341575334, "timer_ticks": 916352, "timer_seconds": 0.916352, "cycle_seconds": 0.9163521742857142, "interrupts": 0}`
- scored: `{"cycles": 517971161, "retired_instructions": 186810327, "ipc": 0.36065777608031735, "timer_ticks": 739959, "timer_seconds": 0.739959, "cycle_seconds": 0.7399588014285714, "interrupts": 0}`
