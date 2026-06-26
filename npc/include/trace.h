#pragma once

#include <stdint.h>

void trace_init(bool enable_itrace);

void trace_cleanup();

// record one submitted instruction
void trace_inst(uint32_t pc, uint32_t inst);

void trace_print_ringbuf();