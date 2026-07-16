module riscv32_ifu
  import riscv32_pkg::*;
#(
    parameter logic [XLEN-1:0] PC_START = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    /* verilator lint_off UNUSEDSIGNAL */
    input redirect_req_t redirect_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic          redirect_valid_i,

    // TODO(P1-IFU-PORT): 在这里加入指令存储器的请求/响应通道，然后再保留下面的
    // fetch 通道。valid/ready 必须与 payload 分离；IFU 是请求生产者和响应消费者。
    // P1 先连接零等待的 riscv32_sim_mem，不要在这一步加入状态机。
    //
    // 建议直接在本 TODO 下方加入以下端口：
    //   output imem_req_t  imem_req_o,
    //   output logic       imem_req_valid_o,
    //   input  logic       imem_req_ready_i,
    //   input  imem_resp_t imem_resp_i,
    //   input  logic       imem_resp_valid_i,
    //   output logic       imem_resp_ready_o,
    //
    // P1 的目标只是让 riscv32_ifu 不再知道 DPI。请求地址仍由 pc_q 产生，响应中的
    // instruction/exception 再被组装为 fetch_entry_t。txn_id 在单事务阶段固定为 '0。
    output imem_req_t  imem_req_o,
    output logic       imem_req_valid_o,
    input  logic       imem_req_ready_i,
    input  imem_resp_t imem_resp_t,
    input  logic       imem_resp_valid_i,
    output logic       imem_resp_ready_o,

    output fetch_entry_t fetch_entry_o,
    output logic         fetch_valid_o,
    input  logic         fetch_ready_i
);

  // TODO(P1-IFU-DPI): 完成上面的 memory 端口后，在这里删除 pmem_read import。
  // 用 imem_req_o.addr = pc_q 发出请求，并使用 imem_resp_i.instruction 代替文件末尾的
  // pmem_read(pc_q)。P1 的组合适配器应满足：
  //   1. imem_req_valid_o 不依赖 imem_req_ready_i；避免 ready->valid 死锁。
  //   2. imem_resp_ready_o 由 fetch_ready_i 驱动。
  //   3. fetch_valid_o 只在收到有效 memory response 时有效。
  //   4. PC 仍只在 fetch_valid_o && fetch_ready_i 或 redirect 时更新。
  // 这样改完以后，IFU 的功能时序与当前 P0 相同，但核心内部已经没有 DPI。
  import "DPI-C" function int pmem_read(input int raddr);

  // TODO(P2-IFU-STATE): 只有 P1 全回归通过并把 memory adapter 改成跨周期响应后，
  // 才在这里加入本地取指事务状态。推荐从以下三个状态开始：
  //   IFU_SEND_REQ  : 保持 imem_req_o/valid，直到 imem_req_ready_i 接收请求；
  //   IFU_WAIT_RESP : 请求已经发出，等待 imem_resp_valid_i；
  //   IFU_HOLD_FETCH: 已保存响应，保持 fetch_entry_o/valid，直到 IDU ready。
  // 建议在本 TODO 下方定义：
  //   typedef enum logic [1:0] { ... } ifu_state_e;
  //   ifu_state_e   state_q, state_d;
  //   logic [XLEN-1:0] request_pc_q, request_pc_d;
  //   fetch_entry_t fetch_entry_q, fetch_entry_d;
  //   logic         discard_resp_q, discard_resp_d;
  //   logic         imem_req_fire, imem_resp_fire;
  //
  // 状态不是因为“有总线”才需要，而是因为请求和响应不在同一周期：IFU 必须记住
  // 哪个 PC 已发出、是否仍有响应在途，以及下游暂停时必须保持哪条指令。这里的状态
  // 只属于 IFU，不要新增全局 Controller。将来 I-cache/MSHR/fetch queue 会扩展这一边界。
  logic [XLEN-1:0] pc_q;
  logic [XLEN-1:0] pc_d;
  logic            fetch_fire;

  // TODO(P2-IFU-FLOW): 实现 P2 状态机时，在这里替换 P1 的组合 valid/fire 逻辑：
  //   - SEND_REQ: imem_req_valid_o=1，地址和 txn_id 在 ready 前保持稳定；
  //   - WAIT_RESP: imem_resp_ready_o=1，在 resp fire 时把 request_pc_q、指令和异常
  //     一起保存到 fetch_entry_q；
  //   - HOLD_FETCH: fetch_valid_o=1，fetch_entry_o=fetch_entry_q，在 fetch_ready_i=0
  //     时二者必须保持不变；
  //   - fetch_fire 后再进入下一次 SEND_REQ，保证 P2 仍然只有一条指令在途。
  // 可以先保留三状态的清晰实现；等协议断言和随机等待测试通过后，再考虑 response
  // bypass 来消除 HOLD_FETCH 带来的额外拍数。
  assign fetch_valid_o = rst_ni;
  assign fetch_fire    = fetch_valid_o && fetch_ready_i;

  // TODO(P2-IFU-PC): 实现跨周期取指时，在这里重写 PC/redirect 更新规则：
  //   1. request_pc_q 保存已经被 memory 接收的地址，不能用可能变化的 pc_q 去标记响应；
  //   2. 当前指令 fetch_fire 时，redirect_valid_i 优先选择 redirect_i.target_pc，
  //      否则下一请求地址为 fetch_entry_q.pc + 4；
  //   3. 若 redirect 在 WAIT_RESP 出现而总线不支持取消，保存目标并置 discard_resp_q；
  //      旧响应回来后只消费并丢弃，绝不能送入 IDU，然后请求 redirect target；
  //   4. reset 后第一个请求地址必须是 PC_START。
  // P2 只有一个 outstanding transaction，因此 txn_id 固定为 0；未来多 outstanding
  // fetch 时再用 txn_id/frontend_tag 区分响应并清除错误路径。
  always_comb begin
    pc_d = pc_q;
    if (redirect_valid_i) begin
      pc_d = redirect_i.target_pc;
    end else if (fetch_fire) begin
      pc_d = pc_q + 32'd4;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      pc_q <= PC_START;
    end else begin
      pc_q <= pc_d;
    end
  end

  // TODO(P1-IFU-RESP): 完成 memory 端口后，在这里删除 pmem_read，改为从
  // imem_resp_i 构造 fetch_entry_o。除了 pc/instruction，还要传播
  // exception_valid、exception_cause 和 exception_tval，避免取指访问错误在适配器处丢失。
  // P2 再把这个组合输出改为上述 fetch_entry_q 的寄存输出。
  always_comb begin
    fetch_entry_o             = '0;
    fetch_entry_o.pc          = pc_q;
    fetch_entry_o.instruction = pmem_read(pc_q);
  end

  // NOTE(P5): branch prediction, I-cache response tracking, and a fetch queue
  // extend this boundary; redirect remains the only external PC-recovery input.

endmodule
