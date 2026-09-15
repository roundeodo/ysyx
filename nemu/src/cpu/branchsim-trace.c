#include <cpu/branchsim-trace.h>

#ifdef CONFIG_BRANCHSIM_TRACE

#include <stdio.h>

#define BRANCHSIM_TRACE_VERSION 1u

typedef struct {
  char magic[8];
  uint32_t version;
  uint32_t address_bytes;
  uint64_t instruction_count;
  uint64_t control_flow_count;
} BranchsimTraceHeader;

typedef struct {
  uint64_t instruction_sequence;
  uint64_t program_counter;
  uint64_t next_program_counter;
  uint32_t instruction;
  uint32_t reserved;
} BranchsimControlFlowRecord;

_Static_assert(sizeof(BranchsimTraceHeader) == 32,
               "unexpected branchsim trace header layout");
_Static_assert(sizeof(BranchsimControlFlowRecord) == 32,
               "unexpected branchsim trace record layout");

static FILE *branchsim_trace_file = NULL;
static uint64_t recorded_instruction_count = 0;
static uint64_t recorded_control_flow_count = 0;

static void write_branchsim_trace_exact(const void *data, size_t size) {
  Assert(fwrite(data, size, 1, branchsim_trace_file) == 1,
         "failed to write branchsim trace");
}

static bool is_control_flow_instruction(uint32_t instruction) {
  const uint32_t opcode = instruction & 0x7fu;
  return opcode == 0x63u || opcode == 0x6fu || opcode == 0x67u;
}

static void close_branchsim_trace(void) {
  if (branchsim_trace_file == NULL) {
    return;
  }

  const BranchsimTraceHeader header = {
      .magic = {'N', 'P', 'C', 'B', 'R', 'T', 'R', '1'},
      .version = BRANCHSIM_TRACE_VERSION,
      .address_bytes = sizeof(vaddr_t),
      .instruction_count = recorded_instruction_count,
      .control_flow_count = recorded_control_flow_count,
  };
  Assert(fseek(branchsim_trace_file, 0, SEEK_SET) == 0,
         "failed to seek branchsim trace header");
  write_branchsim_trace_exact(&header, sizeof(header));
  Assert(fclose(branchsim_trace_file) == 0,
         "failed to close branchsim trace");
  branchsim_trace_file = NULL;
}

void init_branchsim_trace(const char *trace_path) {
  if (trace_path == NULL) {
    return;
  }

  Assert(branchsim_trace_file == NULL,
         "branchsim trace is already initialized");
  branchsim_trace_file = fopen(trace_path, "wb+");
  Assert(branchsim_trace_file != NULL,
         "cannot open branchsim trace file '%s'", trace_path);

  const BranchsimTraceHeader empty_header = {
      .magic = {'N', 'P', 'C', 'B', 'R', 'T', 'R', '1'},
      .version = BRANCHSIM_TRACE_VERSION,
      .address_bytes = sizeof(vaddr_t),
      .instruction_count = 0,
      .control_flow_count = 0,
  };
  write_branchsim_trace_exact(&empty_header, sizeof(empty_header));
  Assert(atexit(close_branchsim_trace) == 0,
         "failed to register branchsim trace finalizer");
}

void record_branchsim_instruction(vaddr_t program_counter,
                                  vaddr_t next_program_counter,
                                  uint32_t instruction) {
  if (branchsim_trace_file == NULL) {
    return;
  }

  const uint64_t instruction_sequence = recorded_instruction_count;
  recorded_instruction_count++;
  if (!is_control_flow_instruction(instruction)) {
    return;
  }

  const BranchsimControlFlowRecord record = {
      .instruction_sequence = instruction_sequence,
      .program_counter = (uint64_t)program_counter,
      .next_program_counter = (uint64_t)next_program_counter,
      .instruction = instruction,
      .reserved = 0,
  };
  write_branchsim_trace_exact(&record, sizeof(record));
  recorded_control_flow_count++;
}

#endif
