#include <nvboard.h>
#include "Vtop.h"


void nvboard_bind_all_pins(Vtop* top);

void single_cycle(Vtop* top){
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
}

void resetn(Vtop* top, int n){
    top->rstn = 0;
    while(n-- > 0){
        single_cycle(top);
    }
    top->rstn = 1;
}


int main(int argc, char** argv) {
    Vtop* top = new Vtop;


    nvboard_bind_all_pins(top);

    nvboard_init();

    resetn(top,10);


    while(1) {

        nvboard_update();
        

        single_cycle(top);
    }


    delete top;
    return 0;
}