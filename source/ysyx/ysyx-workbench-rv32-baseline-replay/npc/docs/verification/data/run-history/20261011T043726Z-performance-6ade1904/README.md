# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale train --cpu-mhz 700 --timing-model device-clock --predictor-enable 1 --dcache-enable 0 --icache-bytes 256 --icache-ways 1 --icache-line 16 --icache-policy 0 --bht-entries 16 --btb-entries 16 --btb-ways 2 --btb-policy 0 --direction-policy 0 --ras-entries 4 --branch-static 2 --early-target 1 --output npc/result/performance/replay-hybrid-train`

- scale: `"train"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 1521484888, "retired_instructions": 266921222, "ipc": 0.17543468496152426, "timer_ticks": 2173550, "timer_seconds": 2.17355, "cycle_seconds": 2.17354984, "interrupts": 0}`
- scored: `{"cycles": 1078887224, "retired_instructions": 186810325, "ipc": 0.1731509288870771, "timer_ticks": 1541265, "timer_seconds": 1.541265, "cycle_seconds": 1.5412674628571428, "interrupts": 0}`
