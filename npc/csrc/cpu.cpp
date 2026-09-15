#include "cpu.h"
#include "perf_observer.h"
#include "difftest.h"
#include "ftrace.h"
#include "trace.h"
#include "watchpoint.h"

#define NPC_STRINGIFY_IMPL(token) #token
#define NPC_STRINGIFY(token) NPC_STRINGIFY_IMPL(token)
#define NPC_GENERATED_HEADER_IMPL(module_class) NPC_STRINGIFY(module_class.h)
#define NPC_GENERATED_HEADER(module_class)                                     \
  NPC_GENERATED_HEADER_IMPL(module_class)

#include NPC_GENERATED_HEADER(TOP_CLASS)
#include NPC_GENERATED_HEADER(TOP_DPI_CLASS)

#include "svdpi.h"

#include <verilated.h>
#include <verilated_vcd_c.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef CONFIG_NVBOARD
#include <nvboard.h>

void nvboard_bind_all_pins(TOP_CLASS *top);
#endif

// ============================================================
// Global simulation objects
// ============================================================

static TOP_CLASS *top = nullptr;
static VerilatedVcdC *tfp = nullptr;

static bool trace_enabled = false;
static bool nvboard_enabled = false;

static uint64_t main_time = 0;
static uint64_t guest_inst_count = 0;
static uint64_t guest_cycle_count = 0;
static uint64_t guest_retired_count = 0;
static uint64_t guest_interrupt_count = 0;
static uint64_t guest_clint_write_count = 0;
static bool good_exit = false;
static PerfObserver perf_observer;
static bool perf_audit_enabled = false;
static uint64_t perf_audit_digest = 14695981039346656037ULL;

static void audit_word(uint64_t value) {
  for (int i = 0; i < 8; ++i) {
    perf_audit_digest = (perf_audit_digest ^ (value & 255)) * 1099511628211ULL;
    value >>= 8;
  }
}
static bool performance_statistics_printed = false;

static const uint64_t MAX_GUEST_INST = 1000000000ULL;
static const uint64_t MAX_CYCLES_WITHOUT_COMMIT = 1000000ULL;
static constexpr int ARCH_GPR_COUNT = 32;

struct CommitEvent {
  bool valid;
  uint32_t perf_flags;
  npc_word_t pc;
  uint32_t instruction;
  npc_word_t next_pc;
};

// RV32I and RV64I share the same 32-register integer ABI names.
static const char *const reg_names[ARCH_GPR_COUNT] = {
    "zero", "ra", "sp", "gp", "tp",  "t0",  "t1", "t2", "s0", "s1", "a0",
    "a1",   "a2", "a3", "a4", "a5",  "a6",  "a7", "s2", "s3", "s4", "s5",
    "s6",   "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"};

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
  top->TOP_CLOCK = 0;
  top->eval();

  if (commit_event != nullptr) {
    set_dpi_scope();
    commit_event->valid = npc_get_commit_valid_dpi() != 0;
    commit_event->pc = static_cast<npc_word_t>(npc_get_commit_pc_dpi());
    commit_event->instruction = (uint32_t)npc_get_commit_inst_dpi();
    commit_event->next_pc =
        static_cast<npc_word_t>(npc_get_commit_next_pc_dpi());
    commit_event->perf_flags = npc_get_perf_flags_dpi();
    if (perf_observer.enabled()) {
      if (commit_event->perf_flags & 2) {
        perf_observer.sample({guest_cycle_count, guest_retired_count,
            npc_get_perf_timer_dpi(), npc_get_perf_load_pc_dpi(),
            npc_get_gpr_dpi(1), guest_interrupt_count});
      }
      if (commit_event->valid) {
        perf_observer.commit(guest_cycle_count, commit_event->pc,
            commit_event->instruction, commit_event->perf_flags & 1);
      }
    }
    if (perf_audit_enabled && commit_event->valid) {
      audit_word(guest_cycle_count);
      audit_word(commit_event->pc);
      audit_word(commit_event->instruction);
      audit_word(commit_event->next_pc);
      audit_word(commit_event->perf_flags & 0x19);
      for (int index = 0; index < 6; ++index)
        audit_word(npc_get_commit_audit_dpi(index));
    }
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

  top->TOP_CLOCK = 1;
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

  top = new TOP_CLASS;

  top->TOP_CLOCK = 0;
  top->TOP_RESET = TOP_RESET_ACTIVE_LEVEL;
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
  guest_cycle_count = 0;
  guest_retired_count = 0;
  guest_interrupt_count = 0;
  guest_clint_write_count = 0;
  good_exit = false;
  perf_audit_digest = 14695981039346656037ULL;
  performance_statistics_printed = false;
  npc_state = NPC_STOP;
  perf_audit_enabled = Verilated::commandArgsPlusMatch("NPC_PERF_AUDIT")[0] != '\0';
  const char *option = Verilated::commandArgsPlusMatch("NPC_PERF_OUTPUT=");
  if (option[0] != '\0') {
    set_dpi_scope();
    perf_observer.open(strchr(option, '=') + 1, npc_get_perf_cpu_hz_dpi(),
                       npc_get_perf_timer_hz_dpi());
  }
}

// ============================================================
// Reset NPC
// ============================================================

void cpu_reset(int n) {
  top->TOP_RESET = TOP_RESET_ACTIVE_LEVEL;

  while (n-- > 0) {
    single_cycle();
  }

  top->TOP_RESET = !TOP_RESET_ACTIVE_LEVEL;
  top->eval();

#ifdef CONFIG_NVBOARD
  if (nvboard_enabled) {
    nvboard_update();
  }
#endif

  npc_state = NPC_STOP;
}

// Read PC

npc_word_t npc_get_pc() {
  set_dpi_scope();
  return static_cast<npc_word_t>(npc_get_pc_dpi());
}

// Read inst
uint32_t npc_get_inst() {
  set_dpi_scope();
  return (uint32_t)npc_get_inst_dpi();
}

// Read GPR

npc_word_t npc_get_gpr(int idx) {
  if (idx == 0) {
    return 0;
  }

  if (idx < 0 || idx >= ARCH_GPR_COUNT) {
    return 0;
  }

  set_dpi_scope();
  return static_cast<npc_word_t>(npc_get_gpr_dpi(idx));
}

npc_word_t npc_get_mstatus() {
  set_dpi_scope();
  return static_cast<npc_word_t>(npc_get_mstatus_dpi());
}

npc_word_t npc_get_mtvec() {
  set_dpi_scope();
  return static_cast<npc_word_t>(npc_get_mtvec_dpi());
}

npc_word_t npc_get_mepc() {
  set_dpi_scope();
  return static_cast<npc_word_t>(npc_get_mepc_dpi());
}

npc_word_t npc_get_mcause() {
  set_dpi_scope();
  return static_cast<npc_word_t>(npc_get_mcause_dpi());
}

npc_word_t npc_get_mtval() {
  set_dpi_scope();
  return static_cast<npc_word_t>(npc_get_mtval_dpi());
}

// ============================================================
// Print registers
// ============================================================

void npc_dump_regs() {
  printf("pc  = 0x%0*llx\n", NPC_WORD_HEX_DIGITS,
         static_cast<unsigned long long>(npc_get_pc()));

  for (int i = 0; i < ARCH_GPR_COUNT; i++) {
    printf("x%-2d %-5s = 0x%0*llx\n", i, reg_names[i],
           NPC_WORD_HEX_DIGITS,
           static_cast<unsigned long long>(npc_get_gpr(i)));
  }
}

// ============================================================
// Read register value by name
// ============================================================

bool npc_reg_str2val(const char *name, npc_word_t *val) {
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

static void print_performance_statistics() {
  const double ipc = guest_cycle_count == 0
                         ? 0.0
                         : static_cast<double>(guest_retired_count) /
                               static_cast<double>(guest_cycle_count);
  printf("NPC performance statistics:\n");
  printf(" retired instructions = %llu\n",
         (unsigned long long)guest_retired_count);
  printf(" CPU cycle            = %llu\n",
         (unsigned long long)guest_cycle_count);
  printf(" IPC                  = %.6f\n", ipc);
  perf_observer.finish(guest_cycle_count, guest_retired_count,
      guest_interrupt_count, guest_clint_write_count, good_exit);
  if (perf_audit_enabled) {
    for (int index = 0; index < ARCH_GPR_COUNT; ++index) audit_word(npc_get_gpr(index));
    audit_word(npc_get_mstatus());
    audit_word(npc_get_mtvec());
    audit_word(npc_get_mepc());
    audit_word(npc_get_mcause());
    audit_word(npc_get_mtval());
    printf("NPC architectural audit = %016llx\n", (unsigned long long)perf_audit_digest);
  }
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
    guest_cycle_count++;
    guest_retired_count += event.perf_flags & 1;
    guest_interrupt_count += (event.perf_flags >> 3) & 1;
    guest_clint_write_count += (event.perf_flags >> 2) & 1;

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

    // AM把EBREAK约定为宿主可见的仿真终止标记。DPI回调在提交沿更新npc_state，
    // 并且发生在single_cycle()返回之前。此时RTL已经按架构产生断点异常，而仿真器
    // 选择在该提交边界结束，因此不能再要求reference执行这个终止标记。
    if (npc_state == NPC_END || npc_state == NPC_ABORT) {
      break;
    }

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
  if ((npc_state == NPC_END || npc_state == NPC_ABORT) &&
      !performance_statistics_printed) {
    print_performance_statistics();
    performance_statistics_printed = true;
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
  npc_word_t a0_val = npc_get_gpr(10);
  npc_word_t pc_val = npc_get_pc();

  good_exit = a0_val == 0;
  if (a0_val == 0) {
    printf("\033[1;32mNPC: HIT GOOD TRAP\033[0m at pc = 0x%0*llx\n",
           NPC_WORD_HEX_DIGITS, static_cast<unsigned long long>(pc_val));
  } else {
    printf(
        "\033[1;31mNPC: HIT BAD TRAP (exit code: %llu)\033[0m at pc = 0x%0*llx\n",
        static_cast<unsigned long long>(a0_val), NPC_WORD_HEX_DIGITS,
        static_cast<unsigned long long>(pc_val));
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
