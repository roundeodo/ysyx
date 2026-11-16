# performance: complete

Command: `npc/scripts/run_microbench_perf.py --scale train --cpu-mhz 700 --timing-model device-clock --icache-bytes 256 --icache-ways 1 --icache-line 16 --icache-policy 0 --dcache-enable 0 --predictor-enable 0 --output npc/result/performance/replay-no-predictor-train`

- scale: `"train"`
- cpu_mhz: `700`
- timing_model: `"device-clock-v1"`
- total: `{"cycles": 1897823221, "retired_instructions": 266883367, "ipc": 0.1406260414810258, "timer_ticks": 2711176, "timer_seconds": 2.711176, "cycle_seconds": 2.71117603, "interrupts": 0}`
- scored: `{"cycles": 1329933355, "retired_instructions": 186810325, "ipc": 0.14046592958787774, "timer_ticks": 1899904, "timer_seconds": 1.899904, "cycle_seconds": 1.8999047928571429, "interrupts": 0}`
