#include <cpu/cachesim-trace.h>

#ifdef CONFIG_CACHESIM_TRACE

#include <limits.h>
#include <stdio.h>

#define CACHESIM_TRACE_VERSION 1u

typedef struct {
  char magic[8];
  uint32_t version;
  uint32_t program_counter_bytes;
  uint64_t instruction_count;
  uint64_t run_count;
} CachesimTraceHeader;

typedef struct {
  uint64_t first_program_counter;
  uint32_t instruction_count;
  int32_t program_counter_stride_bytes;
} CachesimProgramCounterRun;

_Static_assert(sizeof(CachesimTraceHeader) == 32,
               "unexpected cachesim trace header layout");
_Static_assert(sizeof(CachesimProgramCounterRun) == 16,
               "unexpected cachesim trace run layout");

static FILE *cachesim_trace_file = NULL;
static CachesimProgramCounterRun pending_program_counter_run = {};
static uint64_t last_program_counter = 0;
static uint64_t recorded_instruction_count = 0;
static uint64_t recorded_run_count = 0;

static void write_exact(const void *data, size_t size) {
  Assert(fwrite(data, size, 1, cachesim_trace_file) == 1,
         "failed to write cachesim trace");
}

static bool calculate_program_counter_stride(uint64_t previous_program_counter,
                                              uint64_t current_program_counter,
                                              int32_t *stride_bytes) {
  if (current_program_counter >= previous_program_counter) {
    const uint64_t difference = current_program_counter - previous_program_counter;
    if (difference > INT32_MAX) {
      return false;
    }
    *stride_bytes = (int32_t)difference;
    return true;
  }

  const uint64_t difference = previous_program_counter - current_program_counter;
  if (difference > (uint64_t)INT32_MAX + 1u) {
    return false;
  }
  *stride_bytes = difference == (uint64_t)INT32_MAX + 1u
                      ? INT32_MIN
                      : -(int32_t)difference;
  return true;
}

static void flush_pending_program_counter_run(void) {
  if (pending_program_counter_run.instruction_count == 0) {
    return;
  }

  write_exact(&pending_program_counter_run, sizeof(pending_program_counter_run));
  recorded_run_count++;
  pending_program_counter_run = (CachesimProgramCounterRun){};
}

static void close_cachesim_trace(void) {
  if (cachesim_trace_file == NULL) {
    return;
  }

  flush_pending_program_counter_run();

  CachesimTraceHeader header = {
      .magic = {'N', 'P', 'C', 'P', 'C', 'T', 'R', '1'},
      .version = CACHESIM_TRACE_VERSION,
      .program_counter_bytes = sizeof(vaddr_t),
      .instruction_count = recorded_instruction_count,
      .run_count = recorded_run_count,
  };
  Assert(fseek(cachesim_trace_file, 0, SEEK_SET) == 0,
         "failed to seek cachesim trace header");
  write_exact(&header, sizeof(header));
  Assert(fclose(cachesim_trace_file) == 0, "failed to close cachesim trace");
  cachesim_trace_file = NULL;
}

void init_cachesim_trace(const char *trace_path) {
  if (trace_path == NULL) {
    return;
  }

  Assert(cachesim_trace_file == NULL, "cachesim trace is already initialized");
  cachesim_trace_file = fopen(trace_path, "wb+");
  Assert(cachesim_trace_file != NULL,
         "cannot open cachesim trace file '%s'", trace_path);

  CachesimTraceHeader empty_header = {
      .magic = {'N', 'P', 'C', 'P', 'C', 'T', 'R', '1'},
      .version = CACHESIM_TRACE_VERSION,
      .program_counter_bytes = sizeof(vaddr_t),
      .instruction_count = 0,
      .run_count = 0,
  };
  write_exact(&empty_header, sizeof(empty_header));
  Assert(atexit(close_cachesim_trace) == 0,
         "failed to register cachesim trace finalizer");
}

void record_cachesim_program_counter(vaddr_t program_counter) {
  if (cachesim_trace_file == NULL) {
    return;
  }

  const uint64_t current_program_counter = (uint64_t)program_counter;
  recorded_instruction_count++;

  if (pending_program_counter_run.instruction_count == 0) {
    pending_program_counter_run.first_program_counter = current_program_counter;
    pending_program_counter_run.instruction_count = 1;
    pending_program_counter_run.program_counter_stride_bytes = 0;
    last_program_counter = current_program_counter;
    return;
  }

  int32_t current_stride_bytes = 0;
  const bool stride_is_representable = calculate_program_counter_stride(
      last_program_counter, current_program_counter, &current_stride_bytes);

  if (pending_program_counter_run.instruction_count == 1 &&
      stride_is_representable) {
    pending_program_counter_run.program_counter_stride_bytes =
        current_stride_bytes;
    pending_program_counter_run.instruction_count = 2;
    last_program_counter = current_program_counter;
    return;
  }

  if (stride_is_representable &&
      current_stride_bytes ==
          pending_program_counter_run.program_counter_stride_bytes &&
      pending_program_counter_run.instruction_count != UINT32_MAX) {
    pending_program_counter_run.instruction_count++;
    last_program_counter = current_program_counter;
    return;
  }

  flush_pending_program_counter_run();
  pending_program_counter_run.first_program_counter = current_program_counter;
  pending_program_counter_run.instruction_count = 1;
  pending_program_counter_run.program_counter_stride_bytes = 0;
  last_program_counter = current_program_counter;
}

#endif
