#ifndef __CPU_BRANCHSIM_TRACE_H__
#define __CPU_BRANCHSIM_TRACE_H__

#include <common.h>

#ifdef CONFIG_BRANCHSIM_TRACE

void init_branchsim_trace(const char *trace_path);
void record_branchsim_instruction(vaddr_t program_counter,
                                  vaddr_t next_program_counter,
                                  uint32_t instruction);

#else

static inline void init_branchsim_trace(const char *trace_path) {
  (void)trace_path;
}

static inline void record_branchsim_instruction(vaddr_t program_counter,
                                                 vaddr_t next_program_counter,
                                                 uint32_t instruction) {
  (void)program_counter;
  (void)next_program_counter;
  (void)instruction;
}

#endif

#endif
