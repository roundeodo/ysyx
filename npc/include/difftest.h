#pragma once

#include "npc_config.h"

void difftest_init(bool enable, const char *ref_so_file, long img_size);
void difftest_step(npc_word_t pc, npc_word_t next_pc);
void difftest_cleanup();
