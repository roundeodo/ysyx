module riscv32_IFU #(
    parameter DATA_WIDTH = 32,
    parameter PC_START   = 32'h80000000
) (
    input logic                  clk,
    input logic                  rstn,
    // IFU/front-end 不应该知道来源是 jump、branch、trap 还是 mispredict recovery。
    // 前端统一消费 redirect_valid/redirect_pc。
    input logic                  i_if_redirect_valid,
    input logic [DATA_WIDTH-1:0] i_if_redirect_pc,

    // TODO(HP-IFU-1): 用 fetch response channel 替换下面两个散线输出。
    // 推荐端口：fetch_valid_o、fetch_ready_i、fetch_packet_o(fetch_packet_t)。
    // 当 valid=1 且 ready=0 时，PC 和 instruction 必须保持不变；只有 fire 时才能推进队列。
    output logic [DATA_WIDTH-1:0] o_if_pc,
    output logic [DATA_WIDTH-1:0] o_if_instruction
);
  // ==========================================================================
  // IFU design boundary
  // ==========================================================================
  //
  // 当前 IFU 是最小取指单元：PC register + next PC mux + DPI instruction read。
  // C2 阶段可以保持简单，但接口语义要按 redirect 设计。
  //
  // 高性能 CPU 关联：
  //   未来前端会有 branch predictor、BTB、RAS、I-cache、fetch queue。
  //   无论来源是 branch mispredict、jal/jalr、exception、mret，前端最终都需要
  //   一个统一的 redirect_valid/redirect_pc 来改写 fetch PC。
  //
  // Keep PC update priority explicit:
  //   PC 更新优先级应保持：
  //     reset -> RESET_VECTOR
  //     redirect -> redirect_pc
  //     normal -> pc + 4
  //
  //   未来加入 flush/stall/I-cache miss 后，PC enable 和 valid bit 会变复杂；
  //   现在先把 redirect 语义打干净。
  //
  // No valid/ready is required for C2, but keep the boundary in mind:
  //   当前单周期可以不做：
  //     fetch_valid
  //     fetch_ready
  //     instruction response valid
  //     fetch exception metadata
  //
  //   未来流水线/高性能前端需要：
  //     IF/ID valid
  //     frontend stall
  //     I-cache request/response
  //     branch predictor metadata
  //
  //   当前 trace/DPI 读到的是“当前执行指令”。进入流水线后，trace/DiffTest
  //   应迁移到 commit/retire 阶段，不能继续直接拿 IF PC 当提交 PC。

  // TODO(HP-IFU-5): 在这里逐步加入 riscv32_branch_predictor/BTB/RAS 和 riscv32_fetch_queue 边界。
  // predictor 给出 predicted_next_pc 和 prediction metadata；riscv32_fetch_queue 保存 packet，并在 redirect
  // 时按 epoch/flush 清除错误路径。不要让 IDU、riscv32_branch_unit 或 RDU 直接修改内部 predictor state。
  logic [DATA_WIDTH-1:0] pc_reg_Q;
  logic [DATA_WIDTH-1:0] pc_reg_D;

  // TODO(HP-IFU-2): 把下面 DPI import 从 IFU 删除，改成 instruction-memory request/response。
  // Core 侧接口至少需要：imem_req_valid/ready/address 和 imem_resp_valid/ready/data/error。
  // pmem_read() 应迁移到 riscv32_sim_mem；以后替换为 I-cache 时 IFU 不需要再修改。
  import "DPI-C" function int pmem_read(input int raddr);

  // PC mux 只处理正常顺序取指和 redirect。
  // reset 优先级保持在 always_ff 里，不要和 redirect 混在组合 mux 里。
  // TODO(HP-IFU-3): 加入取指阻塞语义后重写 PC enable。
  // 优先级应为 reset > redirect > successful fetch/fire > hold；I-cache miss 或下游不 ready
  // 时保持 pc_reg_Q，不能无条件 pc+4。redirect 还必须清除旧 fetch response/riscv32_fetch_queue 项。
  assign pc_reg_D = i_if_redirect_valid ? i_if_redirect_pc : (pc_reg_Q + 32'd4);
  always_ff @(posedge clk) begin
    if (!rstn) begin
      pc_reg_Q <= PC_START;
    end else begin
      pc_reg_Q <= pc_reg_D;
    end
  end

  assign o_if_pc          = pc_reg_Q;
  // TODO(HP-IFU-4): 完成 HP-IFU-2 后，用 imem_resp_data 形成 fetch_packet_t，删除此组合 DPI 读。
  assign o_if_instruction = pmem_read(o_if_pc);

endmodule
