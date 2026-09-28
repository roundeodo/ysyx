include $(AM_HOME)/scripts/isa/riscv.mk
NPC_CONFIG ?= rv32-baseline
include $(AM_HOME)/scripts/platform/npc.mk
RISCV_MARCH  ?= rv32i_zicsr
COMMON_CFLAGS += -march=$(RISCV_MARCH) -mabi=ilp32  # overwrite
LDFLAGS       += -melf32lriscv                   # overwrite

AM_SRCS += riscv/npc/libgcc/div.S \
           riscv/npc/libgcc/muldi3.S \
           riscv/npc/libgcc/multi3.c \
           riscv/npc/libgcc/ashldi3.c \
           riscv/npc/libgcc/unused.c
