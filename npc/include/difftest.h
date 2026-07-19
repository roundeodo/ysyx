#pragma once

#include <stdint.h>

void difftest_init(bool enable, const char *ref_so_file, long img_size);
void difftest_step(uint32_t pc, uint32_t next_pc);
void difftest_cleanup();