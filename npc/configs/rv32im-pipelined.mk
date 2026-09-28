# Three-cycle multiply, one independent request per cycle.
# NanGate45 AREA3: 117461.078 um^2; all STA groups pass at 700 MHz.
# Experimental option; the stable rv32im-balanced preset remains iterative.
NPC_MUL_PIPELINE_ENABLE ?= 1
NPC_SIM_CPU_FREQ_MHZ ?= 700
include configs/rv32im-balanced.mk
