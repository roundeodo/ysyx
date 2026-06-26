#pragma once

#include <stdint.h>

void trace_init(bool enable_itrace, bool enable_mtrace);

void trace_cleanup();

// record one submitted instruction
void trace_inst(uint32_t pc, uint32_t inst);

void trace_print_ringbuf();

void trace_mem_read(uint32_t addr, int len, uint32_t data);

void trace_mem_write(uint32_t addr, int len, uint32_t data);