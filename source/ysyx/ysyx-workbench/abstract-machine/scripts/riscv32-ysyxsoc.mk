include $(AM_HOME)/scripts/isa/riscv.mk
include $(AM_HOME)/scripts/platform/ysyxsoc.mk

COMMON_CFLAGS += -march=rv32i_zicsr -mabi=ilp32
CFLAGS        += -DMAINARGS=\"$(mainargs)\"
LDFLAGS       += -melf32lriscv

AM_SRCS += riscv/npc/libgcc/div.S \
		   riscv/npc/libgcc/muldi3.S \
		   riscv/npc/libgcc/multi3.c \
		   riscv/npc/libgcc/ashldi3.c \
		   riscv/npc/libgcc/unused.c
