YSYXSOC_START_SOURCE  ?= riscv/ysyxsoc/start.S
YSYXSOC_LINKER_SCRIPT ?= $(AM_HOME)/scripts/ysyxsoc.ld

AM_SRCS := $(YSYXSOC_START_SOURCE) \
			           riscv/ysyxsoc/trm.c \
			           riscv/ysyxsoc/ioe.c \
			           riscv/ysyxsoc/timer.c \
			           riscv/ysyxsoc/uart.c \
			           riscv/ysyxsoc/input.c \
			           riscv/ysyxsoc/gpu.c \
					   riscv/ysyxsoc/gpio.c \
			           riscv/ysyxsoc/spi.c \
			           riscv/ysyxsoc/flash.c \
	           platform/dummy/cte.c \
	           platform/dummy/vme.c \
	           platform/dummy/mpe.c

INC_PATH += $(AM_HOME)/am/src/riscv/ysyxsoc/include

NPC_CONFIG ?= rv32-baseline

# MAINARGS is compiled into trm.o. Rebuild this object for every AM archive
# invocation so changing `mainargs` cannot reuse an object with an old value.
ifeq ($(NAME),am)
$(DST_DIR)/src/riscv/ysyxsoc/trm.o: force
endif

CFLAGS    += -fdata-sections -ffunction-sections
LDSCRIPTS += $(YSYXSOC_LINKER_SCRIPT)
LDFLAGS   += --gc-sections -e _start

image: image-dep
	@$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	@echo + OBJCOPY "->" $(IMAGE_REL).bin
	@$(OBJCOPY) -O binary $(IMAGE).elf $(IMAGE).bin

run: image
	@$(MAKE) -C $(NPC_HOME) sim-image NPC_CONFIG=$(NPC_CONFIG) FLASH_IMG=$(IMAGE).bin
