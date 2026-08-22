#ifndef __CPU_CACHESIM_TRACE_H__
#define __CPU_CACHESIM_TRACE_H__

#include <common.h>

#ifdef CONFIG_CACHESIM_TRACE

void init_cachesim_trace(const char *trace_path);
void record_cachesim_program_counter(vaddr_t program_counter);

#else

static inline void init_cachesim_trace(const char *trace_path) {
  (void)trace_path;
}

static inline void record_cachesim_program_counter(vaddr_t program_counter) {
  (void)program_counter;
}

#endif

#endif
