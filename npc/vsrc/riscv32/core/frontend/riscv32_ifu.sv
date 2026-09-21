// IFU：PC/预测接口 → 两项请求队列 → I-cache响应配对与交付。
module riscv32_ifu
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
#(
    parameter program_counter_t PC_START = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    input redirect_req_t redirect_req_i,
    input logic          redirect_req_valid_i,
    // 维护期间只停止新预测；已展示的 I-cache 请求仍按原握手排空。
    input logic          prediction_enable_i,

    // IFU顺序产生预测请求；预测器用一级寄存响应切断PC自反馈关键路径。非跳转响应被
    // 消费时同拍查询下一 PC：顺序时 PC+4，taken 时直接使用响应目标。
    output program_counter_t   next_pc_predictor_lookup_request_pc_o,
    output fetch_epoch_t       next_pc_predictor_lookup_request_epoch_o,
    output logic               next_pc_predictor_lookup_request_valid_o,
    input  logic               next_pc_predictor_lookup_request_ready_i,
    input  program_counter_t   next_pc_predictor_lookup_response_pc_i,
    input  fetch_epoch_t       next_pc_predictor_lookup_response_epoch_i,
    input  branch_prediction_t next_pc_predictor_prediction_i,
    input  logic               next_pc_predictor_lookup_response_valid_i,
    output logic               next_pc_predictor_lookup_response_ready_o,
    output logic               next_pc_predictor_flush_o,

    // IFU只传递取指语义；cache组织、refill和AXI4均位于I-cache边界之后。
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

  // 共享容量反馈：请求队列的占用数决定预测入口是否还能接收结果。
  localparam int unsigned LOOKUP_QUEUE_ENTRY_COUNT = 2;
  localparam int unsigned LOOKUP_QUEUE_INDEX_WIDTH = $clog2(LOOKUP_QUEUE_ENTRY_COUNT);
  localparam int unsigned LOOKUP_QUEUE_COUNT_WIDTH = $clog2(LOOKUP_QUEUE_ENTRY_COUNT + 1);

  typedef logic [LOOKUP_QUEUE_INDEX_WIDTH-1:0] lookup_queue_index_t;
  typedef logic [LOOKUP_QUEUE_COUNT_WIDTH-1:0] lookup_queue_count_t;

  lookup_queue_count_t lookup_queue_entry_count_q, lookup_queue_entry_count_d;
  logic lookup_queue_enqueue_ready;
  logic lookup_queue_enqueue_event;

  assign lookup_queue_enqueue_ready =
      (lookup_queue_entry_count_q < lookup_queue_count_t'(LOOKUP_QUEUE_ENTRY_COUNT)) ||
      icache_lookup_req_ready_i;

  // 1. PC 与预测查询：顺序请求每拍前进，taken 或 redirect 更新下一查询地址。
  program_counter_t predictor_fetch_pc_q, predictor_fetch_pc_d;
  fetch_epoch_t current_fetch_epoch_q, current_fetch_epoch_d;
  frontend_tag_t next_frontend_tag_q, next_frontend_tag_d;

  logic             predictor_lookup_request_handshake;
  logic             predictor_lookup_response_handshake;
  logic             predictor_lookup_response_is_current;
  logic             predictor_taken_response_event;
  logic             predictor_taken_response_present;
  program_counter_t predicted_next_pc;

  assign lookup_queue_enqueue_event =
      predictor_lookup_response_handshake && predictor_lookup_response_is_current;

  assign predictor_lookup_response_is_current =
      next_pc_predictor_lookup_response_epoch_i == current_fetch_epoch_q;
  assign predicted_next_pc =
      next_pc_predictor_prediction_i.predicted_taken ?
      next_pc_predictor_prediction_i.predicted_target :
      next_pc_predictor_lookup_response_pc_i + program_counter_t'(INSTRUCTION_BYTES);

  // redirect 取消预测流水；taken 响应直接选择本拍的新查询地址。
  assign next_pc_predictor_flush_o                 = redirect_req_valid_i;
  assign next_pc_predictor_lookup_response_ready_o =
      !redirect_req_valid_i &&
      (!predictor_lookup_response_is_current || lookup_queue_enqueue_ready);
  assign predictor_taken_response_present =
      next_pc_predictor_lookup_response_valid_i && predictor_lookup_response_is_current &&
      next_pc_predictor_prediction_i.predicted_taken;
  // 数据选择不等待 ready，握手仅决定何时保存已算出的地址。
  assign next_pc_predictor_lookup_request_pc_o = predictor_taken_response_present ?
      predicted_next_pc : predictor_fetch_pc_q;
  assign next_pc_predictor_lookup_request_epoch_o = current_fetch_epoch_q;
  assign predictor_taken_response_event        =
      predictor_lookup_response_handshake &&
      predictor_lookup_response_is_current &&
      next_pc_predictor_prediction_i.predicted_taken;
  assign next_pc_predictor_lookup_request_valid_o =
      lookup_queue_enqueue_ready && !redirect_req_valid_i && prediction_enable_i;

  assign predictor_lookup_request_handshake =
      next_pc_predictor_lookup_request_valid_o &&
      next_pc_predictor_lookup_request_ready_i;
  assign predictor_lookup_response_handshake =
      next_pc_predictor_lookup_response_valid_i &&
      next_pc_predictor_lookup_response_ready_o;

  always_comb begin
    predictor_fetch_pc_d  = predictor_fetch_pc_q;
    current_fetch_epoch_d = current_fetch_epoch_q;
    next_frontend_tag_d   = next_frontend_tag_q;

    if (redirect_req_valid_i) begin
      current_fetch_epoch_d = current_fetch_epoch_q + fetch_epoch_t'(1);
      predictor_fetch_pc_d  = redirect_req_i.target_pc;
    end else if (predictor_lookup_request_handshake) begin
      predictor_fetch_pc_d = predictor_taken_response_present ?
          (predicted_next_pc + program_counter_t'(INSTRUCTION_BYTES)) :
          (predictor_fetch_pc_q + program_counter_t'(INSTRUCTION_BYTES));
    end else if (predictor_taken_response_event) begin
      predictor_fetch_pc_d = predicted_next_pc;
    end

    if (lookup_queue_enqueue_event) begin
      next_frontend_tag_d = next_frontend_tag_q + frontend_tag_t'(1);
    end
  end

  // PC、epoch与下一请求tag只在本沿更新，分别由上方的推进条件控制。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      predictor_fetch_pc_q  <= PC_START;
      current_fetch_epoch_q <= '0;
      next_frontend_tag_q   <= '0;
    end else begin
      predictor_fetch_pc_q  <= predictor_fetch_pc_d;
      current_fetch_epoch_q <= current_fetch_epoch_d;
      next_frontend_tag_q   <= next_frontend_tag_d;
    end
  end

  // 2. 两项请求队列：先读队首并驱动I-cache，再计算指针/数量，最后更新状态。
  // 请求一旦呈现在I-cache端口上，redirect也不能撤销被反压的valid。
  icache_lookup_req_t lookup_queue_request_array_q[LOOKUP_QUEUE_ENTRY_COUNT];
  branch_prediction_t lookup_queue_prediction_array_q[LOOKUP_QUEUE_ENTRY_COUNT];
  lookup_queue_index_t lookup_queue_read_index_q, lookup_queue_read_index_d;
  lookup_queue_index_t lookup_queue_write_index_q, lookup_queue_write_index_d;

  icache_lookup_req_t lookup_queue_front_request;
  branch_prediction_t lookup_queue_front_prediction;
  logic               lookup_queue_dequeue_event;

  logic icache_lookup_request_handshake;

  always_comb begin
    // 空队列直接展示预测响应，反压时在本沿保存，随后由队首保持。
    lookup_queue_front_request = '0;
    lookup_queue_front_request.fetch_addr = phys_addr_t'(next_pc_predictor_lookup_response_pc_i);
    lookup_queue_front_request.frontend_tag = next_frontend_tag_q;
    lookup_queue_front_request.fetch_epoch = next_pc_predictor_lookup_response_epoch_i;
    lookup_queue_front_prediction = next_pc_predictor_prediction_i;
    if (lookup_queue_entry_count_q != '0) begin
      lookup_queue_front_request    = lookup_queue_request_array_q[lookup_queue_read_index_q];
      lookup_queue_front_prediction = lookup_queue_prediction_array_q[lookup_queue_read_index_q];
    end
  end

  assign icache_lookup_req_o = lookup_queue_front_request;
  // 一旦请求已经呈现在ready/valid通道上，即使redirect到来，也不能撤销valid。
  // 旧epoch请求可以继续握手，返回时按epoch丢弃；这比破坏协议稳定性更可控。
  assign icache_lookup_req_valid_o = (lookup_queue_entry_count_q != '0) ||
      (next_pc_predictor_lookup_response_valid_i && predictor_lookup_response_is_current &&
       !redirect_req_valid_i);
  assign icache_lookup_request_handshake = icache_lookup_req_valid_o && icache_lookup_req_ready_i;

  assign lookup_queue_dequeue_event = icache_lookup_request_handshake;

  always_comb begin
    lookup_queue_read_index_d  = lookup_queue_read_index_q;
    lookup_queue_write_index_d = lookup_queue_write_index_q;
    lookup_queue_entry_count_d = lookup_queue_entry_count_q;

    if (redirect_req_valid_i) begin
      // 当前已经呈现在I-cache端口的front不能在反压时撤销；其后的旧epoch请求尚未
      // 对外可见，可以立即删除。若front本拍握手，则旧队列全部清空。
      if (lookup_queue_entry_count_q == '0) begin
        lookup_queue_entry_count_d = '0;
      end else if (lookup_queue_dequeue_event) begin
        lookup_queue_read_index_d  = lookup_queue_read_index_q + lookup_queue_index_t'(1);
        lookup_queue_write_index_d = lookup_queue_read_index_q + lookup_queue_index_t'(1);
        lookup_queue_entry_count_d = '0;
      end else begin
        lookup_queue_write_index_d = lookup_queue_read_index_q + lookup_queue_index_t'(1);
        lookup_queue_entry_count_d = lookup_queue_count_t'(1);
      end
    end else begin
      unique case ({lookup_queue_enqueue_event, lookup_queue_dequeue_event})
        2'b01: begin
          lookup_queue_read_index_d  = lookup_queue_read_index_q + lookup_queue_index_t'(1);
          lookup_queue_entry_count_d = lookup_queue_entry_count_q - lookup_queue_count_t'(1);
        end
        2'b10: begin
          lookup_queue_write_index_d = lookup_queue_write_index_q + lookup_queue_index_t'(1);
          lookup_queue_entry_count_d = lookup_queue_entry_count_q + lookup_queue_count_t'(1);
        end
        2'b11: begin
          lookup_queue_read_index_d  = lookup_queue_read_index_q + lookup_queue_index_t'(1);
          lookup_queue_write_index_d = lookup_queue_write_index_q + lookup_queue_index_t'(1);
        end
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lookup_queue_read_index_q  <= '0;
      lookup_queue_write_index_q <= '0;
      lookup_queue_entry_count_q <= '0;
    end else begin
      lookup_queue_read_index_q  <= lookup_queue_read_index_d;
      lookup_queue_write_index_q <= lookup_queue_write_index_d;
      lookup_queue_entry_count_q <= lookup_queue_entry_count_d;
      if (lookup_queue_enqueue_event &&
          !((lookup_queue_entry_count_q == '0) && lookup_queue_dequeue_event)) begin
        lookup_queue_request_array_q[lookup_queue_write_index_q].fetch_addr <=
            phys_addr_t'(next_pc_predictor_lookup_response_pc_i);
        lookup_queue_request_array_q[lookup_queue_write_index_q].frontend_tag <=
            next_frontend_tag_q;
        lookup_queue_request_array_q[lookup_queue_write_index_q].fetch_epoch <=
            next_pc_predictor_lookup_response_epoch_i;
        lookup_queue_prediction_array_q[lookup_queue_write_index_q] <=
            next_pc_predictor_prediction_i;
      end
    end
  end

  // 3. 阻塞 I-cache 至多有一个已接受且未响应的 lookup。
  // 同沿旧响应/新请求交接时，旧响应读取旧预测，沿后保存新预测；redirect 不清上下文。
  branch_prediction_t pending_prediction_q;

  logic icache_lookup_response_handshake;
  logic icache_lookup_response_is_current;

  assign icache_lookup_response_is_current =
      icache_lookup_resp_i.fetch_epoch == current_fetch_epoch_q;
  assign icache_lookup_response_handshake =
      icache_lookup_resp_valid_i && icache_lookup_resp_ready_o;

  always_comb begin
    fetch_entry_o                 = '0;
    fetch_entry_o.pc              = program_counter_t'(icache_lookup_resp_i.fetch_addr);
    fetch_entry_o.instruction     = icache_lookup_resp_i.fetch_data;
    fetch_entry_o.frontend_tag    = icache_lookup_resp_i.frontend_tag;
    fetch_entry_o.prediction      = pending_prediction_q;
    fetch_entry_o.exception_valid = icache_lookup_resp_i.access_fault;
    fetch_entry_o.exception_cause = EXC_INSTR_ACCESS_FAULT;
    fetch_entry_o.exception_tval  = xlen_data_t'(icache_lookup_resp_i.fetch_addr);

    fetch_entry_valid_o = icache_lookup_resp_valid_i &&
                          icache_lookup_response_is_current &&
                          !redirect_req_valid_i;
    icache_lookup_resp_ready_o =
        (!icache_lookup_response_is_current || redirect_req_valid_i) ?
        1'b1 : fetch_entry_ready_i;
  end

  // 只在请求被 I-cache 接收时替换这份预测上下文。
  always_ff @(posedge clk_i) begin
    if (icache_lookup_request_handshake)
      pending_prediction_q <=
          lookup_queue_front_prediction;
  end

`ifndef SYNTHESIS
  // 以下存在位和 epoch 副本只用于验证 tag 生命周期，不属于芯片功能状态。
  fetch_epoch_t                  prediction_epoch_by_frontend_tag_array_q[FRONTEND_TAG_COUNT];
  logic [FRONTEND_TAG_COUNT-1:0] prediction_present_vector_q;

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    icache_lookup_request_handshake |->
      ((prediction_present_vector_q == '0) || icache_lookup_response_handshake))
  else $error("Blocking I-cache accepted a second outstanding lookup");

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prediction_present_vector_q <= '0;
    end else begin
      if (icache_lookup_response_handshake)
        prediction_present_vector_q[icache_lookup_resp_i.frontend_tag] <= 1'b0;
      if (icache_lookup_request_handshake) begin
        prediction_epoch_by_frontend_tag_array_q[lookup_queue_front_request.frontend_tag] <=
            lookup_queue_front_request.fetch_epoch;
        prediction_present_vector_q[lookup_queue_front_request.frontend_tag] <= 1'b1;
      end
    end
  end

  a_nontaken_predictor_response_keeps_request_throughput :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (predictor_lookup_response_handshake && predictor_lookup_response_is_current &&
     !next_pc_predictor_prediction_i.predicted_taken)
    |-> predictor_lookup_request_handshake)
  else $error("IFU inserted a bubble after a current non-taken prediction");

  a_taken_response_queries_target :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    predictor_taken_response_event |->
      (next_pc_predictor_lookup_request_pc_o == predicted_next_pc))
  else $error("IFU failed to query the taken prediction target");

  a_predictor_request_stable_while_stalled :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (next_pc_predictor_lookup_request_valid_o &&
     !next_pc_predictor_lookup_request_ready_i && !redirect_req_valid_i)
    |=> (next_pc_predictor_lookup_request_valid_o &&
         $stable(next_pc_predictor_lookup_request_pc_o) && $stable(next_pc_predictor_lookup_request_epoch_o)))
  else $error("IFU changed a predictor request while stalled");

  a_icache_request_stable_while_stalled :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (icache_lookup_req_valid_o && !icache_lookup_req_ready_i)
    |=> (icache_lookup_req_valid_o && $stable(icache_lookup_req_o)))
  else $error("IFU changed an I-cache request while stalled");

  a_current_icache_response_has_prediction :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (icache_lookup_resp_valid_i && icache_lookup_response_is_current)
    |-> (prediction_present_vector_q[icache_lookup_resp_i.frontend_tag] &&
         (prediction_epoch_by_frontend_tag_array_q[icache_lookup_resp_i.frontend_tag] ==
          icache_lookup_resp_i.fetch_epoch)))
  else $error("IFU received a current I-cache response without matching prediction metadata");

  a_frontend_tag_not_reused_while_present :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    icache_lookup_request_handshake
    |-> (!prediction_present_vector_q[lookup_queue_front_request.frontend_tag] ||
         (icache_lookup_response_handshake &&
          (icache_lookup_resp_i.frontend_tag == lookup_queue_front_request.frontend_tag))))
  else $error("IFU reused a frontend tag before the older response completed");

  a_lookup_queue_count_bounded :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    lookup_queue_entry_count_q <= lookup_queue_count_t'(LOOKUP_QUEUE_ENTRY_COUNT))
  else $error("IFU predicted lookup queue overflowed");
`endif

endmodule
