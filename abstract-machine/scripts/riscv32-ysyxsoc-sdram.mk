include $(AM_HOME)/scripts/isa/riscv.mk

YSYXSOC_START_SOURCE  := riscv/ysyxsoc/start-sdram.S
YSYXSOC_LINKER_SCRIPT := $(AM_HOME)/scripts/ysyxsoc-sdram.ld

include $(AM_HOME)/scripts/platform/ysyxsoc.mk

COMMON_CFLAGS += -march=rv32i_zicsr_zifencei -mabi=ilp32
CFLAGS        += -DMAINARGS=\"$(mainargs)\" -Os
LDFLAGS       += -melf32lriscv

AM_SRCS += riscv/npc/libgcc/div.S \
		   riscv/npc/libgcc/muldi3.S \
		   riscv/npc/libgcc/multi3.c \
		   riscv/npc/libgcc/ashldi3.c \
		   riscv/npc/libgcc/unused.c
