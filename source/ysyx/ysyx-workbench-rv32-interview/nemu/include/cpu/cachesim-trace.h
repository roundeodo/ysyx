#ifndef __CPU_CACHESIM_TRACE_H__
#define __CPU_CACHESIM_TRACE_H__

#include <common.h>

#ifdef CONFIG_CACHESIM_TRACE

void init_cachesim_trace(const char *trace_path);
void init_cachesim_data_trace(const char *trace_path);
void record_cachesim_program_counter(vaddr_t program_counter);
void record_cachesim_data_access(vaddr_t address, int transfer_byte_count,
                                 bool is_write);

#else

static inline void init_cachesim_trace(const char *trace_path) {
  (void)trace_path;
}

static inline void record_cachesim_program_counter(vaddr_t program_counter) {
  (void)program_counter;
}

static inline void init_cachesim_data_trace(const char *trace_path) {
  (void)trace_path;
}

static inline void record_cachesim_data_access(vaddr_t address,
                                               int transfer_byte_count,
                                               bool is_write) {
  (void)address;
  (void)transfer_byte_count;
  (void)is_write;
}

#endif

#endif
