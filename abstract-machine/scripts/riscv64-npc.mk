include $(AM_HOME)/scripts/isa/riscv.mk
NPC_CONFIG := rv64-sequential
include $(AM_HOME)/scripts/platform/npc.mk

COMMON_CFLAGS += -march=rv64i_zicsr_zifencei -mabi=lp64 -ffreestanding
LDFLAGS       += -melf64lriscv

AM_SRCS += riscv/npc/libgcc/div.S \
           riscv/npc/libgcc/muldi3.S \
           riscv/npc/libgcc/multi3.c \
           riscv/npc/libgcc/ashldi3.c \
           riscv/npc/libgcc/unused.c
