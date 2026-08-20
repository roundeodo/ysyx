#pragma once
#include "npc_config.h"

#include <stdint.h>

// initialization in verilator
void cpu_init(int argc, char **argv, bool enable_nvboard, bool enable_trace);

// reset NPC
void cpu_reset(int n);

// execute n instruction
void cpu_exec(uint64_t n);

// clean object and wave file
void cpu_cleanup();

// see the program is end or not
bool npc_is_halted();

// read pc
npc_word_t npc_get_pc();

// read inst
uint32_t npc_get_inst();

// read gpr
npc_word_t npc_get_gpr(int idx);

// Read the machine CSRs that form part of the DiffTest architectural state.
npc_word_t npc_get_mstatus();
npc_word_t npc_get_mtvec();
npc_word_t npc_get_mepc();
npc_word_t npc_get_mcause();
npc_word_t npc_get_mtval();

// print gpr value
void npc_dump_regs();

// read gpr with their name
bool npc_reg_str2val(const char *name, npc_word_t *val);
