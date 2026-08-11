module riscv32_ifu
  import riscv32_pkg::*;
#(
    parameter logic [XLEN-1:0] PC_START = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    input redirect_req_t redirect_req_i,
    input logic          redirect_req_valid_i,

    // IFU只描述取指语义，不感知cache组织、refill顺序或AXI4通道。
    output icache_lookup_req_t  icache_lookup_req_o,
    output logic                icache_lookup_req_valid_o,
    input  logic                icache_lookup_req_ready_i,
    input  icache_lookup_resp_t icache_lookup_resp_i,
    input  logic                icache_lookup_resp_valid_i,
    output logic                icache_lookup_resp_ready_o,

    output fetch_entry_t fetch_entry_o,
    output logic         fetch_entry_valid_o,
    input  logic         fetch_entry_ready_i
);

  // 当前前端只允许一个lookup在途。I-cache可以在内部命中、miss或refill，
  // IFU只等待最终lookup response。接口中保留tag和epoch，使后续扩展fetch queue、
  // 多MSHR和多个在途请求时不需重新定义IFU/I-cache边界。
  typedef enum logic [1:0] {
    IFU_INIT,
    IFU_SEND_LOOKUP,
    IFU_WAIT_LOOKUP_RESPONSE,
    IFU_HOLD_FETCH_ENTRY
  } ifu_state_e;

  ifu_state_e state_q;
  ifu_state_e state_d;

  logic [XLEN-1:0] lookup_pc_q;
  logic [XLEN-1:0] lookup_pc_d;
  logic [XLEN-1:0] resume_pc_q;
  logic [XLEN-1:0] resume_pc_d;

  frontend_tag_t next_frontend_tag_q;
  frontend_tag_t next_frontend_tag_d;
  fetch_epoch_t  current_fetch_epoch_q;
  fetch_epoch_t  current_fetch_epoch_d;

  fetch_entry_t buffered_fetch_entry_q;
  fetch_entry_t buffered_fetch_entry_d;
  fetch_entry_t lookup_response_fetch_entry;

  logic lookup_request_handshake;
  logic lookup_response_handshake;
  logic fetch_entry_handshake;
  logic lookup_response_is_current;

  assign lookup_request_handshake  = icache_lookup_req_valid_o && icache_lookup_req_ready_i;
  assign lookup_response_handshake = icache_lookup_resp_valid_i && icache_lookup_resp_ready_o;
  assign fetch_entry_handshake     = fetch_entry_valid_o && fetch_entry_ready_i;

  // epoch只淘汰早于当前控制流的response。产生redirect的当前指令本身必须继续
  // 交付和完成；否则fetch valid会经执行通路和redirect反向控制自身，形成组合环。
  assign lookup_response_is_current =
      icache_lookup_resp_i.fetch_epoch == current_fetch_epoch_q;

  always_comb begin
    lookup_response_fetch_entry                 = '0;
    lookup_response_fetch_entry.pc              = icache_lookup_resp_i.fetch_addr;
    lookup_response_fetch_entry.instruction     = icache_lookup_resp_i.fetch_data;
    lookup_response_fetch_entry.frontend_tag    = icache_lookup_resp_i.frontend_tag;
    lookup_response_fetch_entry.prediction      = '0;
    lookup_response_fetch_entry.exception_valid = icache_lookup_resp_i.access_fault;
    lookup_response_fetch_entry.exception_cause = EXC_INSTR_ACCESS_FAULT;
    lookup_response_fetch_entry.exception_tval  = icache_lookup_resp_i.fetch_addr;
  end

  // Output logic. WAIT状态下本地缓冲一定为空，因此可以无条件接收一个
  // I-cache response。下游ready时response直通IDU；下游反压时在时钟沿保存。
  always_comb begin
    icache_lookup_req_o        = '0;
    icache_lookup_req_valid_o  = 1'b0;
    icache_lookup_resp_ready_o = 1'b0;
    fetch_entry_o              = buffered_fetch_entry_q;
    fetch_entry_valid_o        = 1'b0;

    unique case (state_q)
      IFU_INIT: ;

      IFU_SEND_LOOKUP: begin
        icache_lookup_req_o.fetch_addr   = lookup_pc_q;
        icache_lookup_req_o.frontend_tag = next_frontend_tag_q;
        icache_lookup_req_o.fetch_epoch  = current_fetch_epoch_q;
        icache_lookup_req_valid_o        = 1'b1;
      end

      IFU_WAIT_LOOKUP_RESPONSE: begin
        icache_lookup_resp_ready_o = 1'b1;
        fetch_entry_o              = lookup_response_fetch_entry;
        fetch_entry_valid_o = icache_lookup_resp_valid_i && lookup_response_is_current;
      end

      IFU_HOLD_FETCH_ENTRY: begin
        fetch_entry_o       = buffered_fetch_entry_q;
        fetch_entry_valid_o = 1'b1;
      end

      default: ;
    endcase
  end

  // Next-state logic. redirect在所有状态中都更新resume PC和epoch；已被I-cache接收
  // 的请求不能撤回，所以仍等待并消耗旧epoch响应。valid && !ready期间的
  // lookup payload保持不变；若redirect与请求握手同拍发生，该请求自然成为
  // 旧epoch请求，响应返回后被消耗而不交付。
  always_comb begin
    state_d                 = state_q;
    lookup_pc_d             = lookup_pc_q;
    resume_pc_d             = resume_pc_q;
    next_frontend_tag_d     = next_frontend_tag_q;
    current_fetch_epoch_d   = current_fetch_epoch_q;
    buffered_fetch_entry_d  = buffered_fetch_entry_q;

    if (redirect_req_valid_i) begin
      resume_pc_d           = redirect_req_i.target_pc;
      current_fetch_epoch_d = current_fetch_epoch_q + fetch_epoch_t'(1);
    end

    unique case (state_q)
      IFU_INIT: begin
        state_d = IFU_SEND_LOOKUP;
      end

      IFU_SEND_LOOKUP: begin
        if (lookup_request_handshake) begin
          state_d             = IFU_WAIT_LOOKUP_RESPONSE;
          next_frontend_tag_d = next_frontend_tag_q + frontend_tag_t'(1);
          if (!redirect_req_valid_i) begin
            resume_pc_d = lookup_pc_q + XLEN'(ICACHE_FETCH_BYTES);
          end
        end else if (redirect_req_valid_i) begin
          // 请求尚未被I-cache接收，下一拍可直接用新PC重新发起。
          lookup_pc_d = redirect_req_i.target_pc;
        end
      end

      IFU_WAIT_LOOKUP_RESPONSE: begin
        if (lookup_response_handshake) begin
          if (!lookup_response_is_current) begin
            lookup_pc_d = resume_pc_d;
            state_d     = IFU_SEND_LOOKUP;
          end else if (fetch_entry_handshake) begin
            lookup_pc_d = redirect_req_valid_i ? redirect_req_i.target_pc : resume_pc_q;
            state_d     = IFU_SEND_LOOKUP;
          end else begin
            buffered_fetch_entry_d = lookup_response_fetch_entry;
            state_d                = IFU_HOLD_FETCH_ENTRY;
          end
        end
      end

      IFU_HOLD_FETCH_ENTRY: begin
        if (fetch_entry_handshake) begin
          lookup_pc_d = redirect_req_valid_i ? redirect_req_i.target_pc : resume_pc_q;
          state_d     = IFU_SEND_LOOKUP;
        end
      end

      default: begin
        state_d                = IFU_INIT;
        lookup_pc_d            = PC_START;
        resume_pc_d            = PC_START;
        next_frontend_tag_d    = '0;
        current_fetch_epoch_d  = '0;
        buffered_fetch_entry_d = '0;
      end
    endcase
  end

  // Register update. 状态、PC/请求身份和fetch buffer分类更新，便于后续将
  // 单项buffer扩展为fetch queue。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IFU_INIT;
    end else begin
      state_q <= state_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lookup_pc_q           <= PC_START;
      resume_pc_q           <= PC_START;
      next_frontend_tag_q   <= '0;
      current_fetch_epoch_q <= '0;
    end else begin
      lookup_pc_q           <= lookup_pc_d;
      resume_pc_q           <= resume_pc_d;
      next_frontend_tag_q   <= next_frontend_tag_d;
      current_fetch_epoch_q <= current_fetch_epoch_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      buffered_fetch_entry_q <= '0;
    end else begin
      buffered_fetch_entry_q <= buffered_fetch_entry_d;
    end
  end

endmodule
