AM_SRCS := riscv/ysyxsoc/start.S \
	           riscv/ysyxsoc/trm.c \
	           platform/dummy/ioe.c \
	           platform/dummy/cte.c \
	           platform/dummy/vme.c \
	           platform/dummy/mpe.c

CFLAGS    += -fdata-sections -ffunction-sections
LDSCRIPTS += $(AM_HOME)/scripts/ysyxsoc.ld
LDFLAGS   += --gc-sections -e _start

image: image-dep
	@$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	@echo + OBJCOPY "->" $(IMAGE_REL).bin
	@$(OBJCOPY) -O binary $(IMAGE).elf $(IMAGE).bin

run: image
	@$(MAKE) -C $(NPC_HOME) sim-am IMG=$(IMAGE).bin
