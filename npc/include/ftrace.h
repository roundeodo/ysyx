#pragma once

#include <stdint.h>

void ftrace_init(bool enable_ftrace, const char *elf_path);

void ftrace_cleanup();

void ftrace_update(uint32_t pc, uint32_t inst, uint32_t next_pc);

