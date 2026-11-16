# performance: complete

Command: `/home/yong/ysyx/ysyx-workbench-rv32-interview/npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --host-opt 1 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --keep-artifacts --output /home/yong/ysyx/ysyx-workbench-rv32-interview/npc/result/branch-v3/native-btb-NSL-BT32-fold-700 --btb-entries 32 --btb-ways 4 --btb-policy 2 --btb-index 2 --btb-admission 2 --direction-policy 5 --branch-sc 1 --branch-loop 1`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2617947, "retired_instructions": 831459, "ipc": 0.3175996305501983, "timer_ticks": 3740, "timer_seconds": 0.00374, "cycle_seconds": 0.0037399242857142855, "interrupts": 0}`
- scored: `{"cycles": 1024242, "retired_instructions": 430313, "ipc": 0.42012825094069567, "timer_ticks": 1462, "timer_seconds": 0.001462, "cycle_seconds": 0.0014632028571428572, "interrupts": 0}`
