# RV64 NPC programs boot from Flash and execute from SDRAM in ysyxSoC.
include $(AM_HOME)/scripts/isa/riscv.mk
NPC_CONFIG := rv64-edge-ai
YSYXSOC_START_SOURCE  := riscv/ysyxsoc/start-sdram.S
YSYXSOC_LINKER_SCRIPT := $(AM_HOME)/scripts/ysyxsoc-sdram.ld
include $(AM_HOME)/scripts/platform/ysyxsoc.mk
NPC_MARCH ?= rv64im_zicsr_zifencei
COMMON_CFLAGS += -march=$(NPC_MARCH) -mabi=lp64 -ffreestanding
CFLAGS       += -DMAINARGS=\"$(mainargs)\" -Os
LDFLAGS      += -melf64lriscv
AM_SRCS += riscv/npc/libgcc/div.S \
           riscv/npc/libgcc/muldi3.S \
           riscv/npc/libgcc/multi3.c \
           riscv/npc/libgcc/ashldi3.c \
           riscv/npc/libgcc/unused.c
# Invalidate objects when the ISA, startup or linker configuration changes.
$(OBJS): $(AM_HOME)/scripts/riscv64-npc.mk $(YSYXSOC_LINKER_SCRIPT)
