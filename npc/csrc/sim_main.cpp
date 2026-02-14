#include "Vtop.h"
#include <nvboard.h>
#include <verilated.h>
#include <verilated_vcd_c.h> // 必须引入波形追踪头文件

Vtop *top = new Vtop;

VerilatedVcdC *tfp = nullptr; // 波形文件指针
vluint64_t main_time = 0;     // 仿真时间步长计数器

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
  tfp->open("waveform.vcd"); // 生成的文件名

  nvboard_init();

  reset(10);
  uint32_t current_pc = top->PC_address;
  while (1) {

    nvboard_update();
    single_cycle();
    printf("[Sim] Cycle: %ld | PC: 0x%02X", main_time / 2, current_pc);
  }

  delete top;
  tfp->close();
  return 0;
}