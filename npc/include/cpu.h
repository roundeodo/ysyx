#pragma once
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
uint32_t npc_get_pc();

// read inst
uint32_t npc_get_inst();

// read gpr
uint32_t npc_get_gpr(int idx);

// print gpr value
void npc_dump_regs();

// read gpr with their name
bool npc_reg_str2val(const char *name, uint32_t *val);
