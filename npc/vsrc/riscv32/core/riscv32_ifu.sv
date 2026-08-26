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

    // 预测查询先于I-cache访问运行。预测器返回当前PC的next-PC后，IFU一方面把该PC和
    // prediction放入窄请求队列，另一方面同拍把预测next-PC送回预测器，形成每拍一次查询。
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

  // 两项队列只保存“已完成预测、尚未被I-cache接收”的请求。它不是取指数据buffer，
  // 宽度远小于fetch entry。预测器在队列未满时持续前推，I-cache命中流则从队列每拍
  // 取走一项；由此切断旧实现中的I-cache response -> IFU -> I-cache request组合回路。
  localparam int unsigned LOOKUP_QUEUE_ENTRY_COUNT = 2;
  localparam int unsigned LOOKUP_QUEUE_INDEX_WIDTH = $clog2(LOOKUP_QUEUE_ENTRY_COUNT);
  localparam int unsigned LOOKUP_QUEUE_COUNT_WIDTH = $clog2(LOOKUP_QUEUE_ENTRY_COUNT + 1);

  typedef logic [LOOKUP_QUEUE_INDEX_WIDTH-1:0] lookup_queue_index_t;
  typedef logic [LOOKUP_QUEUE_COUNT_WIDTH-1:0] lookup_queue_count_t;

  icache_lookup_req_t lookup_queue_request_array_q[LOOKUP_QUEUE_ENTRY_COUNT];
  branch_prediction_t lookup_queue_prediction_array_q[LOOKUP_QUEUE_ENTRY_COUNT];
  lookup_queue_index_t lookup_queue_read_index_q, lookup_queue_read_index_d;
  lookup_queue_index_t lookup_queue_write_index_q, lookup_queue_write_index_d;
  lookup_queue_count_t lookup_queue_entry_count_q, lookup_queue_entry_count_d;

  icache_lookup_req_t lookup_queue_front_request;
  branch_prediction_t lookup_queue_front_prediction;
  logic lookup_queue_enqueue_ready;
  logic lookup_queue_enqueue_occurred;
  logic lookup_queue_dequeue_occurred;

  // predictor_request_pending_q保存复位入口或最新redirect目标。正常顺序流不经过该
  // 寄存器：预测响应和下一预测请求同拍握手，从而保持一拍一个next-PC的吞吐。
  logic             predictor_request_pending_q, predictor_request_pending_d;
  program_counter_t predictor_pending_pc_q, predictor_pending_pc_d;
  fetch_epoch_t     predictor_pending_epoch_q, predictor_pending_epoch_d;
  fetch_epoch_t     current_fetch_epoch_q, current_fetch_epoch_d;
  frontend_tag_t    next_frontend_tag_q, next_frontend_tag_d;

  logic predictor_lookup_request_handshake;
  logic predictor_lookup_response_handshake;
  logic predictor_lookup_response_is_current;
  program_counter_t predicted_next_pc;

  // 每个被I-cache实际接收的frontend tag对应一份prediction。I-cache响应原样返回tag，
  // IFU据此恢复预测信息；这样预测器和I-cache可以相差一个流水级而不依赖组合配对。
  branch_prediction_t prediction_by_frontend_tag_q[FRONTEND_TAG_COUNT];
  fetch_epoch_t prediction_epoch_by_frontend_tag_q[FRONTEND_TAG_COUNT];
  logic [FRONTEND_TAG_COUNT-1:0] prediction_present_vector_q;

  logic icache_lookup_request_handshake;
  logic icache_lookup_response_handshake;
  logic icache_lookup_response_is_current;

  assign lookup_queue_enqueue_ready =
      lookup_queue_entry_count_q < lookup_queue_count_t'(LOOKUP_QUEUE_ENTRY_COUNT);
  assign lookup_queue_enqueue_occurred = predictor_lookup_response_handshake;
  assign lookup_queue_dequeue_occurred = icache_lookup_request_handshake;

  always_comb begin
    lookup_queue_front_request    = '0;
    lookup_queue_front_prediction = '0;
    if (lookup_queue_entry_count_q != '0) begin
      lookup_queue_front_request = lookup_queue_request_array_q[lookup_queue_read_index_q];
      lookup_queue_front_prediction =
          lookup_queue_prediction_array_q[lookup_queue_read_index_q];
    end
  end

  assign predictor_lookup_response_is_current =
      next_pc_predictor_lookup_response_epoch_i == current_fetch_epoch_q;
  assign predicted_next_pc = next_pc_predictor_prediction_i.predicted_taken ?
                             next_pc_predictor_prediction_i.predicted_target :
                             next_pc_predictor_lookup_response_pc_i +
                             program_counter_t'(INSTRUCTION_BYTES);

  // redirect使预测器丢弃当前查询级，并在下一拍从新epoch的目标PC重新启动。正常流中，
  // response_ready只取决于窄请求队列空间，不再依赖I-cache、fetch buffer或后端ready。
  assign next_pc_predictor_flush_o = redirect_req_valid_i;
  assign next_pc_predictor_lookup_response_ready_o =
      !redirect_req_valid_i && predictor_lookup_response_is_current &&
      lookup_queue_enqueue_ready;

  always_comb begin
    next_pc_predictor_lookup_request_pc_o    = predictor_pending_pc_q;
    next_pc_predictor_lookup_request_epoch_o = predictor_pending_epoch_q;
    next_pc_predictor_lookup_request_valid_o =
        predictor_request_pending_q && !redirect_req_valid_i;

    if (!predictor_request_pending_q &&
        next_pc_predictor_lookup_response_valid_i &&
        predictor_lookup_response_is_current && lookup_queue_enqueue_ready &&
        !redirect_req_valid_i) begin
      next_pc_predictor_lookup_request_pc_o    = predicted_next_pc;
      next_pc_predictor_lookup_request_epoch_o = current_fetch_epoch_q;
      next_pc_predictor_lookup_request_valid_o = 1'b1;
    end
  end

  assign predictor_lookup_request_handshake =
      next_pc_predictor_lookup_request_valid_o &&
      next_pc_predictor_lookup_request_ready_i;
  assign predictor_lookup_response_handshake =
      next_pc_predictor_lookup_response_valid_i &&
      next_pc_predictor_lookup_response_ready_o;

  always_comb begin
    predictor_request_pending_d = predictor_request_pending_q;
    predictor_pending_pc_d      = predictor_pending_pc_q;
    predictor_pending_epoch_d   = predictor_pending_epoch_q;
    current_fetch_epoch_d       = current_fetch_epoch_q;
    next_frontend_tag_d         = next_frontend_tag_q;

    if (redirect_req_valid_i) begin
      current_fetch_epoch_d       = current_fetch_epoch_q + fetch_epoch_t'(1);
      predictor_request_pending_d = 1'b1;
      predictor_pending_pc_d      = redirect_req_i.target_pc;
      predictor_pending_epoch_d   = current_fetch_epoch_q + fetch_epoch_t'(1);
    end else if (predictor_request_pending_q && predictor_lookup_request_handshake) begin
      predictor_request_pending_d = 1'b0;
    end

    if (lookup_queue_enqueue_occurred) begin
      next_frontend_tag_d = next_frontend_tag_q + frontend_tag_t'(1);
    end
  end

  // 队列只在预测响应真正被消费时写入；请求被I-cache反压时，front payload保持稳定。
  // redirect不撤销已经呈现在I-cache valid通道上的旧epoch请求，避免破坏ready/valid稳定性；
  // 这些请求完成后会按epoch丢弃，新的redirect流随后自然接续。
  always_comb begin
    lookup_queue_read_index_d  = lookup_queue_read_index_q;
    lookup_queue_write_index_d = lookup_queue_write_index_q;
    lookup_queue_entry_count_d = lookup_queue_entry_count_q;

    unique case ({lookup_queue_enqueue_occurred, lookup_queue_dequeue_occurred})
      2'b01: begin
        lookup_queue_read_index_d  = lookup_queue_read_index_q + lookup_queue_index_t'(1);
        lookup_queue_entry_count_d = lookup_queue_entry_count_q - lookup_queue_count_t'(1);
      end
      2'b10: begin
        lookup_queue_write_index_d =
            lookup_queue_write_index_q + lookup_queue_index_t'(1);
        lookup_queue_entry_count_d = lookup_queue_entry_count_q + lookup_queue_count_t'(1);
      end
      2'b11: begin
        lookup_queue_read_index_d  = lookup_queue_read_index_q + lookup_queue_index_t'(1);
        lookup_queue_write_index_d =
            lookup_queue_write_index_q + lookup_queue_index_t'(1);
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      predictor_request_pending_q <= 1'b1;
      predictor_pending_pc_q      <= PC_START;
      predictor_pending_epoch_q   <= '0;
      current_fetch_epoch_q       <= '0;
      next_frontend_tag_q         <= '0;
    end else begin
      predictor_request_pending_q <= predictor_request_pending_d;
      predictor_pending_pc_q      <= predictor_pending_pc_d;
      predictor_pending_epoch_q   <= predictor_pending_epoch_d;
      current_fetch_epoch_q       <= current_fetch_epoch_d;
      next_frontend_tag_q         <= next_frontend_tag_d;
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
      if (lookup_queue_enqueue_occurred) begin
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

  assign icache_lookup_req_o       = lookup_queue_front_request;
  // 一旦请求已经呈现在ready/valid通道上，即使redirect到来，也不能撤销valid。
  // 旧epoch请求可以继续握手，返回时按epoch丢弃；这比破坏协议稳定性更可控。
  assign icache_lookup_req_valid_o = lookup_queue_entry_count_q != '0;
  assign icache_lookup_request_handshake =
      icache_lookup_req_valid_o && icache_lookup_req_ready_i;

  assign icache_lookup_response_is_current =
      icache_lookup_resp_i.fetch_epoch == current_fetch_epoch_q;
  assign icache_lookup_response_handshake =
      icache_lookup_resp_valid_i && icache_lookup_resp_ready_o;

  always_comb begin
    fetch_entry_o                 = '0;
    fetch_entry_o.pc              = program_counter_t'(icache_lookup_resp_i.fetch_addr);
    fetch_entry_o.instruction     = icache_lookup_resp_i.fetch_data;
    fetch_entry_o.frontend_tag    = icache_lookup_resp_i.frontend_tag;
    fetch_entry_o.prediction      =
        prediction_by_frontend_tag_q[icache_lookup_resp_i.frontend_tag];
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

  // prediction表项在请求真正进入I-cache时建立，在对应响应离开时释放。redirect不要求
  // 清空表项：旧epoch响应不会进入fetch buffer，保留表项可继续检查所有已发请求的身份。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prediction_present_vector_q <= '0;
    end else begin
      if (icache_lookup_response_handshake && icache_lookup_response_is_current) begin
        prediction_present_vector_q[icache_lookup_resp_i.frontend_tag] <= 1'b0;
      end
      if (icache_lookup_request_handshake) begin
        prediction_by_frontend_tag_q[lookup_queue_front_request.frontend_tag] <=
            lookup_queue_front_prediction;
        prediction_epoch_by_frontend_tag_q[lookup_queue_front_request.frontend_tag] <=
            lookup_queue_front_request.fetch_epoch;
        prediction_present_vector_q[lookup_queue_front_request.frontend_tag] <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  a_predictor_response_advances_stream :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    predictor_lookup_response_handshake |-> predictor_lookup_request_handshake)
  else $error("IFU consumed a predictor response without launching its predicted successor");

  a_icache_request_stable_while_stalled :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (icache_lookup_req_valid_o && !icache_lookup_req_ready_i)
    |=> (icache_lookup_req_valid_o && $stable(icache_lookup_req_o)))
  else $error("IFU changed an I-cache request while stalled");

  a_current_icache_response_has_prediction :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (icache_lookup_resp_valid_i && icache_lookup_response_is_current)
    |-> (prediction_present_vector_q[icache_lookup_resp_i.frontend_tag] &&
         (prediction_epoch_by_frontend_tag_q[icache_lookup_resp_i.frontend_tag] ==
          icache_lookup_resp_i.fetch_epoch)))
  else $error("IFU received a current I-cache response without matching prediction metadata");

  a_frontend_tag_not_reused_while_present :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    icache_lookup_request_handshake
    |-> !prediction_present_vector_q[lookup_queue_front_request.frontend_tag])
  else $error("IFU reused a frontend tag before the older response completed");

  a_lookup_queue_count_bounded :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    lookup_queue_entry_count_q <= lookup_queue_count_t'(LOOKUP_QUEUE_ENTRY_COUNT))
  else $error("IFU predicted lookup queue overflowed");
`endif

endmodule
