#include "cpu.h"
#include "difftest.h"
#include "ftrace.h"
#include "trace.h"
#include "watchpoint.h"

#include "Vtop.h"
#include "Vtop__Dpi.h"
#include "Vtop___024root.h"

#include "svdpi.h"

#include <verilated.h>
#include <verilated_vcd_c.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef CONFIG_NVBOARD
#include <nvboard.h>

void nvboard_bind_all_pins(Vtop *top);
#endif

// ============================================================
// Global simulation objects
// ============================================================

static Vtop *top = nullptr;
static VerilatedVcdC *tfp = nullptr;

static bool trace_enabled = false;
static bool nvboard_enabled = false;

static uint64_t main_time = 0;
static uint64_t guest_inst_count = 0;

static const uint64_t MAX_GUEST_INST = 1000000000ULL;
static const uint64_t MAX_CYCLES_WITHOUT_COMMIT = 1000000ULL;
static constexpr int ARCH_GPR_COUNT = 32;

struct CommitEvent {
  bool valid;
  uint32_t pc;
  uint32_t instruction;
  uint32_t next_pc;
};

// RV32I ABI register names. SDB accepts both these names and the x0-x31 numeric names.
static const char *const reg_names[ARCH_GPR_COUNT] = {
    "zero", "ra", "sp",  "gp",  "tp", "t0", "t1", "t2",
    "s0",   "s1", "a0",  "a1",  "a2", "a3", "a4", "a5",
    "a6",   "a7", "s2",  "s3",  "s4", "s5", "s6", "s7",
    "s8",   "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

// NPC state

enum NPCState { NPC_STOP, NPC_RUNNING, NPC_END, NPC_ABORT };

static NPCState npc_state = NPC_STOP;

// dpi scope
static svScope top_dpi_scope = nullptr;

extern "C" void npc_set_dpi_scope() { top_dpi_scope = svGetScope(); }

static inline void set_dpi_scope() {
  if (top_dpi_scope == nullptr) {
    printf("Error: DPI scope has not been set.\n");
    printf("Check whether top.sv has initial begin npc_set_dpi_scope(); end\n");
    exit(1);
  }

  svSetScope(top_dpi_scope);
}

// Execute one clock cycle
static void single_cycle(CommitEvent *commit_event = nullptr) {
  top->clk = 0;
  top->eval();

  if (commit_event != nullptr) {
    set_dpi_scope();
    commit_event->valid = npc_get_commit_valid_dpi() != 0;
    commit_event->pc = (uint32_t)npc_get_commit_pc_dpi();
    commit_event->instruction = (uint32_t)npc_get_commit_inst_dpi();
    commit_event->next_pc = (uint32_t)npc_get_commit_next_pc_dpi();
  }

  if (trace_enabled && tfp != nullptr) {
    tfp->dump(main_time);
  }

#ifdef CONFIG_NVBOARD
  if (nvboard_enabled) {
    nvboard_update();
  }
#endif

  main_time++;

  top->clk = 1;
  top->eval();

  if (trace_enabled && tfp != nullptr) {
    tfp->dump(main_time);
  }

#ifdef CONFIG_NVBOARD
  if (nvboard_enabled) {
    nvboard_update();
  }
#endif

  main_time++;
}

// ============================================================
// Initialize Verilator
// ============================================================

void cpu_init(int argc, char **argv, bool enable_nvboard, bool enable_trace) {
  Verilated::commandArgs(argc, argv);

  trace_enabled = enable_trace;

#ifdef CONFIG_NVBOARD
  nvboard_enabled = enable_nvboard;
#else
  if (enable_nvboard) {
    printf("Warning: this binary is not built with NVBoard support.\n");
  }
  nvboard_enabled = false;
#endif

  if (trace_enabled) {
    Verilated::traceEverOn(true);
  }

  top = new Vtop;

  top->clk = 0;
  top->rstn = 0;
  top->eval();

  if (top_dpi_scope == nullptr) {
    printf("Error: DPI scope was not initialized after first eval.\n");
    printf("Check top.sv initial block and npc_set_dpi_scope import.\n");
    exit(1);
  }

  if (trace_enabled) {
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("waveform.vcd");
  }

#ifdef CONFIG_NVBOARD
  if (nvboard_enabled) {
    nvboard_bind_all_pins(top);
    nvboard_init();
  }
#endif

  main_time = 0;
  guest_inst_count = 0;
  npc_state = NPC_STOP;
}

// ============================================================
// Reset NPC
// ============================================================

void cpu_reset(int n) {
  top->rstn = 0;

  while (n-- > 0) {
    single_cycle();
  }

  top->rstn = 1;
  top->eval();

#ifdef CONFIG_NVBOARD
  if (nvboard_enabled) {
    nvboard_update();
  }
#endif

  npc_state = NPC_STOP;
}

// Read PC

uint32_t npc_get_pc() {
  set_dpi_scope();
  return (uint32_t)npc_get_pc_dpi();
}

// Read inst
uint32_t npc_get_inst() {
  set_dpi_scope();
  return (uint32_t)npc_get_inst_dpi();
}

// Read GPR

uint32_t npc_get_gpr(int idx) {
  if (idx == 0) {
    return 0;
  }

  if (idx < 0 || idx >= ARCH_GPR_COUNT) {
    return 0;
  }

  set_dpi_scope();
  return (uint32_t)npc_get_gpr_dpi(idx);
}

// ============================================================
// Print registers
// ============================================================

void npc_dump_regs() {
  printf("pc  = 0x%08x\n", npc_get_pc());

  for (int i = 0; i < ARCH_GPR_COUNT; i++) {
    printf("x%-2d %-5s = 0x%08x\n", i, reg_names[i], npc_get_gpr(i));
  }
}

// ============================================================
// Read register value by name
// ============================================================

bool npc_reg_str2val(const char *name, uint32_t *val) {
  if (name == nullptr || val == nullptr) {
    return false;
  }

  if (strcmp(name, "pc") == 0) {
    *val = npc_get_pc();
    return true;
  }

  for (int i = 0; i < ARCH_GPR_COUNT; i++) {
    if (strcmp(name, reg_names[i]) == 0) {
      *val = npc_get_gpr(i);
      return true;
    }
  }

  if (strcmp(name, "fp") == 0) {
    *val = npc_get_gpr(8);
    return true;
  }

  // x0 ~ x31
  if (name[0] == 'x') {
    char *end = nullptr;
    long idx = strtol(name + 1, &end, 10);

    if (*end == '\0' && idx >= 0 && idx < ARCH_GPR_COUNT) {
      *val = npc_get_gpr((int)idx);
      return true;
    }
  }

  return false;
}

// Execute n instructions

void cpu_exec(uint64_t n) {
  if (npc_state == NPC_END) {
    printf("NPC has already ended.\n");
    return;
  }

  if (npc_state == NPC_ABORT) {
    printf("NPC has aborted.\n");
    return;
  }

  npc_state = NPC_RUNNING;

  uint64_t retired = 0;
  uint64_t cycles_without_commit = 0;

  while (retired < n) {
    if (Verilated::gotFinish()) {
      npc_state = NPC_END;
      break;
    }

    if (guest_inst_count >= MAX_GUEST_INST) {
      printf("\033[1;31mNPC: Simulation Timeout!\033[0m\n");
      npc_state = NPC_ABORT;
      break;
    }

    CommitEvent event{};
    single_cycle(&event);

    if (!event.valid) {
      cycles_without_commit++;
      if (cycles_without_commit >= MAX_CYCLES_WITHOUT_COMMIT) {
        printf("\033[1;31mNPC: no commit for %llu cycles\033[0m\n",
               (unsigned long long)cycles_without_commit);
        npc_state = NPC_ABORT;
        break;
      }
      continue;
    }

    cycles_without_commit = 0;
    guest_inst_count++;
    retired++;

    trace_inst(event.pc, event.instruction);
    ftrace_update(event.pc, event.instruction, event.next_pc);
    difftest_step(event.pc, event.next_pc);
    if (npc_state == NPC_END || npc_state == NPC_ABORT) {
      break;
    }

    if (check_watchpoints()) {
      npc_state = NPC_STOP;
      break;
    }
  }

  if (npc_state == NPC_RUNNING) {
    npc_state = NPC_STOP;
  }
}

// ============================================================
// Whether NPC has ended
// ============================================================

bool npc_is_halted() { return npc_state == NPC_END || npc_state == NPC_ABORT; }

// ============================================================
// DPI-C callback for ebreak
// ============================================================

extern "C" void ebreak_halt() {
  uint32_t a0_val = npc_get_gpr(10);
  uint32_t pc_val = npc_get_pc();

  if (a0_val == 0) {
    printf("\033[1;32mNPC: HIT GOOD TRAP\033[0m at pc = 0x%08x\n", pc_val);
  } else {
    printf(
        "\033[1;31mNPC: HIT BAD TRAP (exit code: %u)\033[0m at pc = 0x%08x\n",
        a0_val, pc_val);
  }

  npc_state = NPC_END;
}

// ============================================================
// Cleanup
// ============================================================

void cpu_cleanup() {
  if (top != nullptr) {
    top->final();
  }

  if (trace_enabled && tfp != nullptr) {
    tfp->close();
    delete tfp;
    tfp = nullptr;
  }

#ifdef CONFIG_NVBOARD
  if (nvboard_enabled) {
    nvboard_quit();
  }
#endif

  if (top != nullptr) {
    delete top;
    top = nullptr;
  }
}
