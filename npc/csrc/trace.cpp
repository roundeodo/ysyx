#include "trace.h"

#include <capstone/capstone.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static bool itrace_enabled = false;
static bool mtrace_enabled = false;

static csh cs_handle;
static bool capstone_ready = false;

#define ITRACE_RINGBUF_SIZE 16

struct ITraceRecord {
  uint32_t pc;
  uint32_t inst;
  char disasm[128];
};

static ITraceRecord itrace_ringbuf[ITRACE_RINGBUF_SIZE];
static uint64_t itrace_count = 0;

// convert one 32-bit RISCV instruction into disassembly string
static void disassemble_inst(uint32_t pc, uint32_t inst, char *buf,
                             size_t buf_size) {
  if (buf == nullptr || buf_size == 0) {
    return;
  }

  buf[0] = '\0';

  if (!capstone_ready) {
    snprintf(buf, buf_size, "capstone-not-ready");
    return;
  }

  uint8_t code[4];
  code[0] = inst & 0xff;
  code[1] = (inst >> 8) & 0xff;
  code[2] = (inst >> 16) & 0xff;
  code[3] = (inst >> 24) & 0xff;

  cs_insn *insn = nullptr;
  // insn is the result  and this should be a level-2 pointer
  size_t count = cs_disasm(cs_handle, code, sizeof(code), pc, 1, &insn);

  if (count > 0) {
    if (insn[0].op_str != nullptr && strlen(insn[0].op_str) > 0) {
      snprintf(buf, buf_size, "%-8s %s", insn[0].mnemonic, insn[0].op_str);
    } else {
      snprintf(buf, buf_size, "%s", insn[0].mnemonic);
    }

    cs_free(insn, count);
  } else {
    snprintf(buf, buf_size, "invalid");
  }
}

// trace module initialization

void trace_init(bool enable_itrace, bool enable_mtrace) {
  itrace_enabled = enable_itrace;
  mtrace_enabled = enable_mtrace;
  itrace_count = 0;

  cs_err err = cs_open(CS_ARCH_RISCV, CS_MODE_RISCV32, &cs_handle);

  if (err != CS_ERR_OK) {
    capstone_ready = false;
    printf("itrace: failed to initialize Capstone: %s\n", cs_strerror(err));
    return;
  }

  capstone_ready = true;

  cs_option(cs_handle, CS_OPT_DETAIL, CS_OPT_OFF);

  if (itrace_enabled) {
    printf("itrace: enabled with Capstone\n");
  }

  if (mtrace_enabled) {
    printf("mtrace: enabled\n");
  }
}

// trace cleanup
void trace_cleanup() {
  if (capstone_ready) {
    cs_close(&cs_handle);
    capstone_ready = false;
  }
}

// record one instruction
void trace_inst(uint32_t pc, uint32_t inst) {
  char disasm_buf[128];

  disassemble_inst(pc, inst, disasm_buf, sizeof(disasm_buf));

  uint64_t idx = itrace_count % ITRACE_RINGBUF_SIZE;

  itrace_ringbuf[idx].pc = pc;
  itrace_ringbuf[idx].inst = inst;
  snprintf(itrace_ringbuf[idx].disasm, sizeof(itrace_ringbuf[idx].disasm), "%s",
           disasm_buf);

  itrace_count++;

  if (!itrace_enabled) {
    return;
  }

  printf("itrace: 0x%08x: %08x  %s\n", pc, inst, disasm_buf);
}

// print recent instructions
void trace_print_ringbuf() {
  printf("Recent executed instructions:\n");

  uint64_t total = itrace_count;
  uint64_t n = total < ITRACE_RINGBUF_SIZE ? total : ITRACE_RINGBUF_SIZE;
  uint64_t start = total >= n ? total - n : 0;

  for (uint64_t i = start; i < total; i++) {
    uint64_t idx = i % ITRACE_RINGBUF_SIZE;

    printf("  0x%08x: %08x  %s\n", itrace_ringbuf[idx].pc,
           itrace_ringbuf[idx].inst, itrace_ringbuf[idx].disasm);
  }
}

// mtrace
void trace_mem_read(uint32_t addr, int len, uint32_t data) {
  if (!mtrace_enabled) {
    return;
  }

  printf("mtrace: READ  addr=0x%08x len=%d data=0x%08x\n", addr, len, data);
}

void trace_mem_write(uint32_t addr, int len, uint32_t data) {
  if (!mtrace_enabled) {
    return;
  }

  printf("mtrace: WRITE addr=0x%08x len=%d data=0x%08x\n", addr, len, data);
}