# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --dcache-enable 0 --output npc/result/performance/replay-no-dcache-test`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 5810938, "retired_instructions": 821349, "ipc": 0.14134533873877161, "timer_ticks": 8301, "timer_seconds": 0.008301, "cycle_seconds": 0.00830134, "interrupts": 0}`
- scored: `{"cycles": 3146593, "retired_instructions": 430311, "ipc": 0.13675457868240348, "timer_ticks": 4496, "timer_seconds": 0.004496, "cycle_seconds": 0.004495132857142857, "interrupts": 0}`
