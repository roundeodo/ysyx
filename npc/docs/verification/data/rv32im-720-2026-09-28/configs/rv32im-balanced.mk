# RV32IM: same caches/predictor as RV32I, with an iterative M unit.
# NanGate45 AREA3 / 820 MHz mapping: 106339.086 um^2; all STA groups pass at 700 MHz.
# Evidence: docs/verification/RV32IM_FRONTEND_TIMING_2026-09-28.md
NPC_MULDIV_ENABLE  ?= 1
NPC_SIM_CPU_FREQ_MHZ ?= 700
include configs/rv32-balanced.mk
