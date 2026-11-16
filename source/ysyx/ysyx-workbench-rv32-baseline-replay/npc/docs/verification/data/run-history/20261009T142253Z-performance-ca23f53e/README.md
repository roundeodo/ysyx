# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale train --cpu-mhz 700 --dcache-enable 0 --output npc/result/performance/replay-no-dcache-train`

- scale: `"train"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 1538604340, "retired_instructions": 266919199, "ipc": 0.17348137663513935, "timer_ticks": 2198006, "timer_seconds": 2.198006, "cycle_seconds": 2.1980062, "interrupts": 0}`
- scored: `{"cycles": 1087053361, "retired_instructions": 186810325, "ipc": 0.17185018850238393, "timer_ticks": 1552931, "timer_seconds": 1.552931, "cycle_seconds": 1.5529333728571428, "interrupts": 0}`
