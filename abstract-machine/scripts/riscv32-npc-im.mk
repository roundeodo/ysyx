# Separate ARCH keeps RV32I and RV32IM objects and AM libraries isolated.
RISCV_MARCH := rv32im_zicsr_zifencei
NPC_CONFIG := rv32im-balanced
include $(AM_HOME)/scripts/riscv32-npc.mk
