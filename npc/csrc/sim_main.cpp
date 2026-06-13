#include "Vtop.h"
#include "Vtop___024root.h"
#include "mem.h"
#include <iostream>
#include <nvboard.h>
#include <verilated.h>
#include <verilated_vcd_c.h> // wave tracing head

Vtop *top = new Vtop;
bool enable_trace = false;
VerilatedVcdC *tfp = nullptr; // wave file pointer
vluint64_t main_time = 0;     //

void nvboard_bind_all_pins(Vtop *top);

bool sim_halted = false;

extern "C" void ebreak_halt() {
  uint32_t a0_val = top->rootp->top__DOT__U_RF__DOT__rf[10];
  uint32_t pc_val = top->rootp->top__DOT__U_IFU__DOT__pc_reg_Q;
  if (a0_val == 0) {
    printf("\033[1;32mNPC: HIT GOOD TRAP\033[0m at pc = 0x%08x\n", pc_val);
  } else {
    printf(
        "\033[1;31mNPC: HIT BAD TRAP (exit code: %d)\033[0m at pc = 0x%08x\n",
        a0_val, pc_val);
  }
  sim_halted = true;
}

void single_cycle() {
  top->clk = 0;
  top->eval();
  if (tfp && enable_trace)
    tfp->dump(main_time++);
  top->clk = 1;
  top->eval();
  if (tfp && enable_trace)
    tfp->dump(main_time++);
}

void reset(int n) {
  top->rstn = 0;
  while (n-- > 0)
    single_cycle();
  top->rstn = 1;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);
  tfp = new VerilatedVcdC;
  enable_trace = false;
  // nvboard_bind_all_pins(top);

  top->trace(tfp, 99);
  tfp->open("waveform.vcd");

  if (argc > 1) {
    load_bin(argv[1]);
    std::cout << "NPC:load image" << argv[1] << std::endl;
  } else {
    std::cout << "NPC: No image, MEM is empty" << std::endl;
  }
  // const char *path = NULL;
  // load_bin(path);
  // uint32_t halt_offset = 0x224;

  // if (halt_offset < MEM_SIZE) {
  //   *(uint32_t *)(pmem + halt_offset) = 0x00100073;
  //   printf("NPC: Injected ebreak at [Offset: 0x%x] (Physical: 0x%08x)\n",
  //          halt_offset, 0x80000000 + halt_offset);
  // }
  // nvboard_init();

  reset(10);
  uint64_t limit = 1000000000;
  while (!sim_halted && !Verilated::gotFinish() && main_time < limit) {
    single_cycle();
  }
  if (main_time >= limit) {
    printf("\033[1;31mNPC: Simulation Timeout!\033[0m\n");
    return -1;
  }

  delete top;
  tfp->close();
  // nvboard_quit();
  return 0;
}