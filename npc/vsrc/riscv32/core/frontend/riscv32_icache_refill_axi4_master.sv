// I-cache本地refill协议到完整AXI4读事务的边界adapter。
// v1只允许一个事务在途，但完整保留ARID/ARLEN/ARSIZE/ARBURST和RID/RLAST语义。
module riscv32_icache_refill_axi4_master
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
#(
    parameter logic [AXI4_ID_WIDTH-1:0] READ_TRANSACTION_ID = '0
) (
    input logic clk_i,
    input logic rst_ni,

    input  icache_refill_req_t refill_req_i,
    input  logic               refill_req_valid_i,
    output logic               refill_req_ready_o,

    output icache_refill_resp_t refill_resp_o,
    output logic                refill_resp_valid_o,
    input  logic                refill_resp_ready_i,

    output axi4_manager_to_target_t axi_manager_o,
    input  axi4_target_to_manager_t axi_manager_i
);

  typedef enum logic [1:0] {
    REFILL_IDLE,
    REFILL_SEND_READ_ADDRESS,
    REFILL_RECEIVE_READ_DATA
  } refill_adapter_state_e;

  refill_adapter_state_e state_q;
  refill_adapter_state_e state_d;

  icache_refill_req_t refill_req_q;
  icache_refill_req_t refill_req_d;
  icache_word_index_t received_word_index_q;
  icache_word_index_t received_word_index_d;

  logic [AXI4_ADDR_WIDTH-1:0] requested_start_addr;

  logic refill_req_handshake;
  logic axi_read_address_handshake;
  logic axi_read_data_handshake;
  logic response_has_access_fault;

  assign refill_req_handshake = refill_req_valid_i && refill_req_ready_o;
  assign axi_read_address_handshake =
      axi_manager_o.ar_valid && axi_manager_i.ar_ready;
  assign axi_read_data_handshake = axi_manager_i.r_valid && axi_manager_o.r_ready;
  assign response_has_access_fault =
      (axi_manager_i.r.resp != AXI4_RESP_OKAY) &&
      (axi_manager_i.r.resp != AXI4_RESP_EXOKAY);

  // 完整line从line base开始；单word uncached fetch直接访问critical word地址。
  // 这里不能始终使用line_base_addr，否则同一line内非零word的不可缓存取指会读错数据。
  always_comb begin
    requested_start_addr = refill_req_q.line_base_addr;

    if (refill_req_q.requested_word_count == icache_refill_word_count_t'(1)) begin
      requested_start_addr =
          refill_req_q.line_base_addr +
          AXI4_ADDR_WIDTH'(refill_req_q.critical_word_index * ICACHE_FETCH_BYTES);
    end
  end

  // 第一段：组合输出。写通道在I-cache adapter中永久关闭。
  always_comb begin
    refill_req_ready_o  = state_q == REFILL_IDLE;
    refill_resp_o       = '0;
    refill_resp_valid_o = 1'b0;
    axi_manager_o       = '0;

    unique case (state_q)
      REFILL_SEND_READ_ADDRESS: begin
        axi_manager_o.ar.addr  = requested_start_addr;
        axi_manager_o.ar.id    = READ_TRANSACTION_ID;
        axi_manager_o.ar.len   = 8'(refill_req_q.requested_word_count - 1'b1);
        axi_manager_o.ar.size  = 3'($clog2(ICACHE_FETCH_BYTES));
        axi_manager_o.ar.burst = AXI4_BURST_INCR;
        axi_manager_o.ar_valid = 1'b1;
      end

      REFILL_RECEIVE_READ_DATA: begin
        refill_resp_o.word_data         = axi_manager_i.r.data;
        refill_resp_o.word_index        = received_word_index_q;
        refill_resp_o.last_word         = axi_manager_i.r.last;
        refill_resp_o.access_fault      = response_has_access_fault;
        refill_resp_o.transaction_index = refill_req_q.transaction_index;
        refill_resp_valid_o             = axi_manager_i.r_valid;
        axi_manager_o.r_ready           = refill_resp_ready_i;
      end

      default: ;
    endcase
  end

  // 第二段：事务状态和beat位置。单word uncached fetch仍使用LEN=0的INCR事务。
  always_comb begin
    state_d               = state_q;
    refill_req_d          = refill_req_q;
    received_word_index_d = received_word_index_q;

    unique case (state_q)
      REFILL_IDLE: begin
        if (refill_req_handshake) begin
          refill_req_d          = refill_req_i;
          if (refill_req_i.requested_word_count == icache_refill_word_count_t'(1)) begin
            received_word_index_d = refill_req_i.critical_word_index;
          end else begin
            received_word_index_d = '0;
          end
          state_d               = REFILL_SEND_READ_ADDRESS;
        end
      end

      REFILL_SEND_READ_ADDRESS: begin
        if (axi_read_address_handshake) begin
          state_d = REFILL_RECEIVE_READ_DATA;
        end
      end

      REFILL_RECEIVE_READ_DATA: begin
        if (axi_read_data_handshake) begin
          if (axi_manager_i.r.last) begin
            refill_req_d          = '0;
            received_word_index_d = '0;
            state_d               = REFILL_IDLE;
          end else begin
            received_word_index_d = received_word_index_q + icache_word_index_t'(1);
          end
        end
      end

      default: begin
        state_d               = REFILL_IDLE;
        refill_req_d          = '0;
        received_word_index_d = '0;
      end
    endcase
  end

  // 第三段：状态、请求身份和beat计数分别更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= REFILL_IDLE;
    else state_q <= state_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) refill_req_q <= '0;
    else refill_req_q <= refill_req_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) received_word_index_q <= '0;
    else received_word_index_q <= received_word_index_d;
  end

endmodule
