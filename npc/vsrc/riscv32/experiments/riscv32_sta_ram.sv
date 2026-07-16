// STA-only 256x32 read/write memory for the ysyx single-cycle frequency exercise.
// Read is combinational; masked write is synchronous.
module riscv32_sta_ram #(
    parameter int unsigned DEPTH_WORDS = 256,
    parameter int unsigned ADDR_W      = $clog2(DEPTH_WORDS)
) (
    input logic clk_i,

    input  logic [ADDR_W-1:0] addr_i,
    input  logic              wen_i,
    input  logic [      31:0] wdata_i,
    input  logic [       3:0] wmask_i,
    output logic [      31:0] rdata_o
);

  // TODO(STA-RAM-ARRAY): 在本位置声明 256x32-bit 存储阵列。为了让 byte write
  // 清晰可综合，可以声明一个 32-bit word array，也可以声明 4 个 8-bit byte-lane
  // array。当前实验固定 DEPTH_WORDS=256，总容量 1 KiB。

  // TODO(STA-RAM-READ): 在本位置实现组合读：rdata_o 在当前周期由 mem[addr_i]
  // 得到。手册中的单周期 STA 实验不需要 ren；读操作本身不会改变 memory 状态。

  // TODO(STA-RAM-WRITE): 紧接着在这里实现 posedge masked write。只在 wen_i=1 时
  // 更新 wmask_i 指定的字节，例如对 lane i 写入：
  //   if (wmask_i[i]) mem_q[addr_i][8*i +: 8] <= wdata_i[8*i +: 8];
  // 必须使用非阻塞赋值；wmask=0 时任何存储位都不能改变。

endmodule
