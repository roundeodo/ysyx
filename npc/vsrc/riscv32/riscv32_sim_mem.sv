// Simulation-only memory adapter. Do not add this file to a synthesis filelist.
module riscv32_sim_mem
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  imem_req_t  imem_req_i,
    input  logic       imem_req_valid_i,
    output logic       imem_req_ready_o,
    output imem_resp_t imem_resp_o,
    output logic       imem_resp_valid_o,
    input  logic       imem_resp_ready_i,

    input  mem_req_t  dmem_req_i,
    input  logic      dmem_req_valid_i,
    output logic      dmem_req_ready_o,
    output mem_resp_t dmem_resp_o,
    output logic      dmem_resp_valid_o,
    input  logic      dmem_resp_ready_i
);

  // TODO(P1-SIM-MEM-DPI): 在这里导入当前 mem.cpp 提供的三个函数：
  //   pmem_read(addr)                  -> instruction word；
  //   pmem_read_data(addr, len)        -> aligned raw data word；
  //   pmem_write(addr, wdata, wmask)   -> masked store/MMIO side effect。
  // DPI 允许存在于本 simulation adapter，但禁止出现在 riscv32_core/IFU/LSU 中。

  // TODO(P1-SIM-MEM-COMB): 先在这里实现零等待组合 adapter，保持 P0 行为：
  //   1. response payload 由当前 request payload 和 DPI read 组合生成；
  //   2. req_ready 由对应 resp_ready 约束，resp_valid 由 req_valid 产生，使一次 fire
  //      同时代表请求被接收和响应被消费；
  //   3. instruction/data 两个通道彼此独立；
  //   4. dmem load 的 size 映射为 1/2/4 byte；store 只在 dmem req fire 的时钟沿
  //      调用一次 pmem_write；MEM_CMD_NONE 不得访问 memory；
  //   5. response 的 txn_id 原样返回，当前阶段 exception 字段先置零。
  // 完成后先跑 P0 全回归。此步骤只改变模块边界，不改变 memory latency。

  // TODO(P2-SIM-MEM-LATENCY): P1 全回归后，用每个端口各自的一项 pending/response
  // 寄存器替换上面的组合 adapter，模拟同步 memory 的一拍响应：
  //   - req fire 时锁存 request，并暂时撤销 req_ready；
  //   - 下一拍产生 resp_valid 和响应 payload；
  //   - resp_valid=1 且 resp_ready=0 时必须保持 payload/valid 不变；
  //   - resp fire 后清空 pending，才允许下一请求；
  //   - imem 与 dmem 使用独立状态，允许它们并行，但每个端口最多一个 outstanding。
  // 可以在协议正确后加入参数化随机等待，用于验证 IFU/LSU 在 backpressure 下不丢事务。
  // 这一步仍可用 DPI 作为仿真 memory 的数据后端；“去掉 DPI”的硬性边界是可综合 core。

endmodule
