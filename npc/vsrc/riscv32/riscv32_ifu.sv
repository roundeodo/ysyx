module riscv32_ifu
  import riscv32_pkg::*;
#(
    parameter logic [XLEN-1:0] PC_START = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    /* verilator lint_off UNUSEDSIGNAL */
    input redirect_req_t redirect_req_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic          redirect_req_valid_i,

    output imem_req_t  imem_req_o,
    output logic       imem_req_valid_o,
    input  logic       imem_req_ready_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  imem_resp_t imem_resp_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic       imem_resp_valid_i,
    output logic       imem_resp_ready_o,

    output fetch_entry_t fetch_entry_o,
    output logic         fetch_entry_valid_o,
    input  logic         fetch_entry_ready_i
);

  typedef enum logic [1:0] {
    IFU_SEND_REQ,
    IFU_WAIT_RESP,
    IFU_HOLD_FETCH
  } ifu_state_e;

  ifu_state_e state_q;
  ifu_state_e state_d;

  // imem_req_pc_q在请求阻塞和等待响应期间保持不变，用于关联响应与取指PC。
  logic [XLEN-1:0] imem_req_pc_q;
  logic [XLEN-1:0] imem_req_pc_d;
  // next_pc_q保存当前事务结束后的顺序PC，redirect到达时保存redirect target。
  logic [XLEN-1:0] next_pc_q;
  logic [XLEN-1:0] next_pc_d;

  // 该寄存器只在memory响应已经被IFU接收、但IDU尚未ready时使用。
  // 无反压时，响应在IFU_WAIT_RESP中直接旁路到IDU，不额外增加一拍。
  fetch_entry_t fetch_entry_q;
  fetch_entry_t fetch_entry_d;
  fetch_entry_t imem_resp_fetch_entry;

  // 已经发出的请求无法取消时，记录其响应属于错误路径。
  logic discard_imem_resp_q;
  logic discard_imem_resp_d;

  logic imem_req_handshake;
  logic imem_resp_handshake;
  logic fetch_entry_handshake;

  assign imem_req_handshake    = imem_req_valid_o && imem_req_ready_i;
  assign imem_resp_handshake   = imem_resp_valid_i && imem_resp_ready_o;
  assign fetch_entry_handshake = fetch_entry_valid_o && fetch_entry_ready_i;

  // 取指异常仍作为有效fetch向后传递。只有到达有序commit边界后，trap controller
  // 才能更新CSR并产生redirect，从而保持精确异常语义。
  always_comb begin
    imem_resp_fetch_entry                 = '0;
    imem_resp_fetch_entry.pc              = imem_req_pc_q;
    imem_resp_fetch_entry.instruction     = imem_resp_i.instruction;
    imem_resp_fetch_entry.frontend_tag    = '0;
    imem_resp_fetch_entry.prediction      = '0;
    imem_resp_fetch_entry.exception_valid = imem_resp_i.exception_valid;
    imem_resp_fetch_entry.exception_cause = imem_resp_i.exception_cause;
    imem_resp_fetch_entry.exception_tval  = imem_resp_i.exception_tval;
  end

  // WAIT_RESP采用fall-through旁路：IDU ready时response和fetch同拍握手；
  // IDU not ready时IFU接收response，并在时钟沿保存到fetch_entry_q。
  // Moore output
  always_comb begin
    imem_req_o          = '0;
    imem_req_valid_o    = 1'b0;
    imem_resp_ready_o   = 1'b0;
    fetch_entry_o       = fetch_entry_q;
    fetch_entry_valid_o = 1'b0;

    unique case (state_q)
      IFU_SEND_REQ: begin
        imem_req_valid_o  = 1'b1;
        imem_req_o.addr   = imem_req_pc_q;
        imem_req_o.txn_id = '0;
      end

      IFU_WAIT_RESP: begin
        // 此状态下本地响应缓冲为空，所以总能接收一个memory响应。错误路径响应也要
        // 接走以释放memory通道，但discard或redirect有效时不能交给IDU。
        imem_resp_ready_o   = 1'b1;
        fetch_entry_o       = imem_resp_fetch_entry;
        fetch_entry_valid_o = imem_resp_valid_i && !discard_imem_resp_q;
      end

      IFU_HOLD_FETCH: begin
        // redirect同周期压低valid，避免缓冲中的错误路径指令与IDU完成握手。
        fetch_entry_o       = fetch_entry_q;
        fetch_entry_valid_o = 1'b1;
      end

      default: ;
    endcase
  end

  // next state
  always_comb begin
    state_d             = state_q;
    imem_req_pc_d       = imem_req_pc_q;
    next_pc_d           = next_pc_q;
    fetch_entry_d       = fetch_entry_q;
    discard_imem_resp_d = discard_imem_resp_q;

    unique case (state_q)
      IFU_SEND_REQ: begin
        // valid && !ready期间不能改变request payload。redirect先记录为后续PC，
        // 当前旧请求仍完成传输，其响应回来后再丢弃。
        if (redirect_req_valid_i) begin
          next_pc_d           = redirect_req_i.target_pc;
          discard_imem_resp_d = 1'b1;
        end

        if (imem_req_handshake) begin
          state_d = IFU_WAIT_RESP;
          if (!discard_imem_resp_q && !redirect_req_valid_i) begin
            next_pc_d = imem_req_pc_q + XLEN'(4);
          end
        end
      end

      IFU_WAIT_RESP: begin
        // 已握手的memory请求无法撤回。redirect到达后保存新PC，并等待旧响应回来。
        if (redirect_req_valid_i) begin
          next_pc_d           = redirect_req_i.target_pc;
          discard_imem_resp_d = 1'b1;
        end

        if (imem_resp_handshake) begin
          if (discard_imem_resp_q || redirect_req_valid_i) begin
            // 消耗错误路径响应，但不构造fetch。
            imem_req_pc_d       = redirect_req_valid_i ? redirect_req_i.target_pc : next_pc_q;
            next_pc_d           = redirect_req_valid_i ? redirect_req_i.target_pc : next_pc_q;
            discard_imem_resp_d = 1'b0;
            state_d             = IFU_SEND_REQ;
          end else if (fetch_entry_handshake) begin
            // 无反压快速路径：响应当拍直接交给IDU，不进入HOLD_FETCH。
            imem_req_pc_d = next_pc_q;
            state_d       = IFU_SEND_REQ;
          end else begin
            // IDU反压：响应已被IFU接收，保存后由HOLD_FETCH持续展示。
            fetch_entry_d = imem_resp_fetch_entry;
            state_d       = IFU_HOLD_FETCH;
          end
        end
      end

      IFU_HOLD_FETCH: begin
        if (redirect_req_valid_i) begin
          // 缓冲中的fetch尚未交给IDU，可以直接丢弃。
          imem_req_pc_d       = redirect_req_i.target_pc;
          next_pc_d           = redirect_req_i.target_pc;
          discard_imem_resp_d = 1'b0;
          state_d             = IFU_SEND_REQ;
        end else if (fetch_entry_handshake) begin
          imem_req_pc_d = next_pc_q;
          state_d       = IFU_SEND_REQ;
        end
      end

      default: begin
        state_d             = IFU_SEND_REQ;
        imem_req_pc_d       = PC_START;
        next_pc_d           = PC_START;
        fetch_entry_d       = '0;
        discard_imem_resp_d = 1'b0;
      end
    endcase
  end

  // Register update
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q             <= IFU_SEND_REQ;
      imem_req_pc_q       <= PC_START;
      next_pc_q           <= PC_START;
      fetch_entry_q       <= '0;
      discard_imem_resp_q <= 1'b0;
    end else begin
      state_q             <= state_d;
      imem_req_pc_q       <= imem_req_pc_d;
      next_pc_q           <= next_pc_d;
      fetch_entry_q       <= fetch_entry_d;
      discard_imem_resp_q <= discard_imem_resp_d;
    end
  end

  // NOTE(P5): branch prediction, I-cache response tracking, and a fetch queue
  // extend this boundary; redirect remains the only external PC-recovery input.

endmodule
