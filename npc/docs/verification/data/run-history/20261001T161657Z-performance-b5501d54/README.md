# performance: complete

Command: `/home/yong/ysyx/ysyx-workbench-rv32-interview/npc/scripts/run_microbench_perf.py --scale test --cpu-mhz 700 --host-opt 1 --icache-bytes 1024 --icache-ways 4 --icache-line 32 --icache-policy 13 --keep-artifacts --output /home/yong/ysyx/ysyx-workbench-rv32-interview/npc/result/branch-v3/native-btb-BT32-fold-700 --btb-entries 32 --btb-ways 4 --btb-policy 2 --btb-index 2 --btb-admission 2`

- scale: `"test"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 2674178, "retired_instructions": 831993, "ipc": 0.3111210248532446, "timer_ticks": 3821, "timer_seconds": 0.003821, "cycle_seconds": 0.003820254285714286, "interrupts": 0}`
- scored: `{"cycles": 1040425, "retired_instructions": 430313, "ipc": 0.4135934834322512, "timer_ticks": 1488, "timer_seconds": 0.001488, "cycle_seconds": 0.0014863214285714286, "interrupts": 0}`
