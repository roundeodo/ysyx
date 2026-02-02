#include "Vtop.h"
#include <nvboard.h>

void nvboard_bind_all_pins(Vtop *top);

int main(int argc, char **argv) {
  Vtop *top = new Vtop;

  nvboard_bind_all_pins(top);

  nvboard_init();

  while (1) {

    nvboard_update();

    top->eval();
  }

  delete top;
  return 0;
}