CROSS_COMPILE ?= riscv64-linux-gnu-

CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
OBJDUMP := $(CROSS_COMPILE)objdump

BUILD_DIR := build
ELF       := $(BUILD_DIR)/flash-xip-payload.elf
BIN       := $(BUILD_DIR)/flash-xip-payload.bin
DISASM    := $(BUILD_DIR)/flash-xip-payload.txt

CFLAGS := -march=rv32i_zicsr -mabi=ilp32 -O2 \
	-ffreestanding -ffunction-sections \
	-fno-builtin -fno-pic -fno-pie -fno-stack-protector \
	-fno-asynchronous-unwind-tables -Wall -Wextra

LDFLAGS := -nostdlib -nostartfiles -static -no-pie \
	-Wl,-T,linker.ld -Wl,--build-id=none -Wl,--gc-sections

all: $(BIN) $(DISASM)

$(BUILD_DIR):
	mkdir -p $@

$(ELF): flash_entry.c linker.ld | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) flash_entry.c -o $@

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

$(DISASM): $(ELF)
	$(OBJDUMP) -d -M no-aliases $< > $@

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all clean