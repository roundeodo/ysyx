// Synthesizable data memory used after the P2 bus protocol is stable.
module riscv32_sram
  import riscv32_pkg::*;
#(
    parameter int unsigned DEPTH_WORDS = 256,
    parameter logic [XLEN-1:0] BASE_ADDR = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    input  mem_req_t  dmem_req_i,
    input  logic      dmem_req_valid_i,
    output logic      dmem_req_ready_o,
    output mem_resp_t dmem_resp_o,
    output logic      dmem_resp_valid_o,
    input  logic      dmem_resp_ready_i
);

  // TODO(P2-SRAM-STORAGE): 在这里声明 4 个 byte-lane array，或声明 32-bit word array
  // 并对 wmask 做逐字节写入。byte lanes 更直接地表达 SB/SH/SW 的写使能。
  // index 使用 (addr - BASE_ADDR) >> 2；同时检查范围和 size 对齐。

  // TODO(P2-SRAM-PROTOCOL): 在这里实现与 riscv32_rom 相同的一拍 req/resp 协议。
  // load 返回对齐的 32-bit raw word，由 LSU 根据 addr[1:0]/size 完成选择和符号扩展；
  // store 按 wmask 写入，并仍返回一次 completion response，使 LSU 的 load/store 控制统一。
  // response stall 时必须保持 valid/payload；txn_id 原样返回。

  // TODO(P2-SRAM-VERIFY): 为同址 masked write、byte/half/word load、未对齐访问、越界
  // 访问和 response backpressure 编写 directed test。之后再加入随机 memory latency。
  // 256 words 只用于教程中的 1 KiB STA 对比；正式 SoC SRAM 容量应由集成层设置。

endmodule
