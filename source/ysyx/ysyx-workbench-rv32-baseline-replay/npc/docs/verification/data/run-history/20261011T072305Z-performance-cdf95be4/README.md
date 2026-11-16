# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --timing-model device-clock --predictor-enable 0 --dcache-enable 0 --icache-bytes 256 --icache-ways 1 --icache-line 16 --icache-policy 0 --branch-static 0 --early-target 0 --verify-observer --output npc/result/performance/replay-icache256-no-predictor-test`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 6785149, "retired_instructions": 801960, "ipc": 0.11819342508174839, "timer_ticks": 9693, "timer_seconds": 0.009693, "cycle_seconds": 0.00969307, "interrupts": 0}`
- scored: `{"cycles": 3601628, "retired_instructions": 430311, "ipc": 0.11947680326785554, "timer_ticks": 5146, "timer_seconds": 0.005146, "cycle_seconds": 0.0051451828571428574, "interrupts": 0}`
