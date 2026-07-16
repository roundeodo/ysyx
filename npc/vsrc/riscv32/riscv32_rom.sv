// Synthesizable instruction memory used after the P2 bus protocol is stable.
module riscv32_rom
  import riscv32_pkg::*;
#(
    parameter int unsigned DEPTH_WORDS = 256,
    parameter logic [XLEN-1:0] BASE_ADDR = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    input  imem_req_t  imem_req_i,
    input  logic       imem_req_valid_i,
    output logic       imem_req_ready_o,
    output imem_resp_t imem_resp_o,
    output logic       imem_resp_valid_o,
    input  logic       imem_resp_ready_i
);

  // TODO(P2-ROM-STORAGE): 在这里声明 DEPTH_WORDS x 32-bit 的存储阵列。
  // word index 应由 (addr - BASE_ADDR) >> 2 得到，并检查 4-byte 对齐和地址范围。
  // 越界/未对齐请求通过 imem_resp_t 的 exception 字段报告，不能静默回零。

  // TODO(P2-ROM-PROTOCOL): 在这里实现一拍同步读和一项 response holding register：
  // request fire 后下一拍给出 response；response 被 backpressure 时保持稳定；同一端口
  // 最多一个 outstanding。txn_id 必须从请求复制到响应。

  // TODO(P2-ROM-INIT): 为 directed RTL test/FPGA 选择可复现的初始化方式，例如参数化
  // INIT_FILE + $readmemh。当前 C++ load_bin() 只会填充 mem.cpp 的 pmem，不会自动填充
  // 本 RTL 阵列；不要在没有 image bridge 的情况下直接用它运行 AM 二进制。
  // 教程指定的 256 words 仅用于 1 KiB STA 实验。正式 SoC memory 容量必须参数化。

endmodule
