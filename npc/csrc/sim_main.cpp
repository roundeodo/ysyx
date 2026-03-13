#include "Vtop.h"
#include "Vtop___024root.h"
#include <nvboard.h>
#include <verilated.h>
#include <verilated_vcd_c.h> // wave tracing head

Vtop *top = new Vtop;

VerilatedVcdC *tfp = nullptr; // wave file pointer
vluint64_t main_time = 0;     //

void nvboard_bind_all_pins(Vtop *top);

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
  nvboard_bind_all_pins(top);

  top->trace(tfp, 99);
  tfp->open("waveform.vcd");

  nvboard_init();

  reset(10);
  while (1) {

    nvboard_update();
    single_cycle();
  }

  delete top;
  tfp->close();
  return 0;
}