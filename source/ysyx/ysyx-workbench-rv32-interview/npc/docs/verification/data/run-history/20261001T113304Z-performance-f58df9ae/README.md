# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --direction-policy 5 --tage-base 16 --tage-entries 8 --tage-tags 6 --tage-lengths 3 7 --early-ras 1 --early-target 1 --host-opt 1 --verify-observer --keep-artifacts --output npc/result/branch-v3/native-NSmallER-held`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2639766, "retired_instructions": 831921, "ipc": 0.31514952461695467, "timer_ticks": 3771, "timer_seconds": 0.003771, "cycle_seconds": 0.0037710942857142856, "interrupts": 0}`
- scored: `{"cycles": 1035949, "retired_instructions": 430313, "ipc": 0.41538048687724977, "timer_ticks": 1481, "timer_seconds": 0.001481, "cycle_seconds": 0.0014799271428571428, "interrupts": 0}`
