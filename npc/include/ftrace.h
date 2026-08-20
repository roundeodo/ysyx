#pragma once

#include "npc_config.h"

void ftrace_init(bool enable_ftrace, const char *elf_path);

void ftrace_cleanup();

void ftrace_update(npc_word_t pc, uint32_t inst, npc_word_t next_pc);
