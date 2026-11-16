#pragma once

#include "npc_config.h"

#include <stdint.h>

void trace_init(bool enable_itrace, bool enable_mtrace);

void trace_cleanup();

// record one submitted instruction
void trace_inst(npc_word_t pc, uint32_t inst);

void trace_print_ringbuf();

void trace_mem_read(uint32_t addr, int len, uint64_t data);

void trace_mem_write(uint32_t addr, int len, uint64_t data);
