#include "Vkeyboard_top.h"
#include <nvboard.h>

Vkeyboard_top *keyboard_top = new Vkeyboard_top;

void nvboard_bind_all_pins(Vkeyboard_top *keyboard_top);

void single_cycle() {
  keyboard_top->clk = 0;
  keyboard_top->eval();
  keyboard_top->clk = 1;
  keyboard_top->eval();
}

void reset(int n) {
  keyboard_top->rstn = 0;
  while (n-- > 0)
    single_cycle();
  keyboard_top->rstn = 1;
}

int main(int argc, char **argv) {
  nvboard_bind_all_pins(keyboard_top);

  nvboard_init();

  reset(10);

  while (1) {

    nvboard_update();
    single_cycle();
  }

  delete keyboard_top;
  return 0;
}