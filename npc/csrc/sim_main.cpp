#include "Vtop.h"
#include "Vtop___024root.h"
#include "mem.h"
#include <iostream>
#include <nvboard.h>
#include <verilated.h>
#include <verilated_vcd_c.h> // wave tracing head

Vtop *top = new Vtop;

VerilatedVcdC *tfp = nullptr; // wave file pointer
vluint64_t main_time = 0;     //

void nvboard_bind_all_pins(Vtop *top);

bool sim_halted = false;

extern "C" void ebreak_halt() {
  std::cout << "[NPC_TRAP] ebreak instruction detected" << std::endl;
  sim_halted = true;
}

void single_cycle() {
  top->clk = 0;
  top->eval();
  if (tfp)
    tfp->dump(main_time++);
  top->clk = 1;
  top->eval();
  if (tfp)
    tfp->dump(main_time++);
}

void reset(int n) {
  top->rstn = 0;
  while (n-- > 0)
    single_cycle();
  top->rstn = 1;
}

int main(int argc, char **argv) {

  Verilated::traceEverOn(true);
  tfp = new VerilatedVcdC;
  // nvboard_bind_all_pins(top);

  top->trace(tfp, 99);
  tfp->open("waveform.vcd");

  // if (argc > 1) {
  //   load_bin(argv[1]);
  //   std::cout << "NPC:load image" << argv[1] << std::endl;
  // } else {
  //   std::cout << "NPC: No image, MEM is empty" << std::endl;
  // }
  const char *path = "/home/yong/ysyx/logisim-bin/sum.bin";
  load_bin(path);
  uint32_t halt_offset = 0x224;

  if (halt_offset < MEM_SIZE) {
    *(uint32_t *)(pmem + halt_offset) = 0x00100073;
    printf("NPC: Injected ebreak at [Offset: 0x%x] (Physical: 0x%08x)\n",
           halt_offset, 0x80000000 + halt_offset);
  }
  // nvboard_init();

  reset(10);
  while (!sim_halted && !Verilated::gotFinish() && main_time < 10000) {

    // nvboard_update();
    single_cycle();
  }

  delete top;
  tfp->close();
  // nvboard_quit();
  return 0;
}