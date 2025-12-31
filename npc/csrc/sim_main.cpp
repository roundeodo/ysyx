#include <nvboard.h>  // 【关键】引入 NVBoard 头文件
#include <stdio.h>
#include <stdlib.h>

#include "Vtop.h"
#include "verilated.h"

// 如果你想保留波形，可以保留这两行，不需要可以删掉
#include "verilated_vcd_c.h"

// 【关键】声明引脚绑定函数，这个函数在 auto_bind.cpp 中定义
// 链接器会将它们连接起来
void nvboard_bind_all_pins(Vtop* top);

// 定义一个控制仿真的函数，通常用来处理时钟或单步执行
// 对于组合逻辑（像你现在的异或门），这个可能很简单
static void single_cycle() {
    // 组合逻辑不需要时钟翻转，但如果是时序逻辑这里需要处理 clk
    // top->clk = 0; top->eval();
    // top->clk = 1; top->eval();
}

int main(int argc, char** argv) {
    VerilatedContext* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);

    Vtop* top = new Vtop{contextp};

    // --- NVBoard 初始化开始 ---

    // 1. 绑定引脚：将 Verilator 仿真模型的信号与 NVBoard 的虚拟引脚连接
    nvboard_bind_all_pins(top);

    // 2. 初始化 NVBoard
    nvboard_init();

    // --- NVBoard 初始化结束 ---

    // 以前的随机测试 while 循环要删掉，换成死循环
    // 因为硬件是永远在线的，直到你关闭窗口
    while (1) {
        // 3. 更新 NVBoard 的状态（读取键盘/开关，更新 LED/VGA）
        nvboard_update();

        // 4. 执行电路逻辑
        top->eval();

        // 如果你的电路很复杂，或者想看波形，可以在这里 dump 波形
        // 但注意：NVBoard 跑得很快，波形文件会瞬间变得巨大，建议调试时再开
    }

    // 清理工作（通常跑不到这里，因为是死循环，除非你在 update 里检测退出信号）
    nvboard_quit();
    delete top;
    delete contextp;
    return 0;
}
