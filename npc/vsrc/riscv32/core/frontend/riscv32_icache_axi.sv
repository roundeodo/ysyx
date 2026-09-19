// I-cache本地refill协议到完整AXI4读事务的边界adapter。
// v1只允许一个事务在途，但完整保留ARID/ARLEN/ARSIZE/ARBURST和RID/RLAST语义。
module riscv32_icache_axi
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
#(
    // refill事务ID的宽度来自全局AXI fabric配置。
    parameter logic [MEM_AXI_ID_WIDTH-1:0] READ_TRANSACTION_ID = '0
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

  // adapter在AR握手后只需记住burst长度和本地事务身份。line_base_addr与
  // critical_word_index已经折叠进current_word_addr，避免为同一地址保存两份状态。
  typedef struct packed {
    icache_refill_word_count_t        requested_word_count;
    icache_refill_transaction_index_t transaction_index;
  } refill_transaction_context_t;

  refill_transaction_context_t refill_transaction_context_q;
  refill_transaction_context_t refill_transaction_context_d;
  icache_word_index_t          received_word_index_q;
  icache_word_index_t          received_word_index_d;

  localparam int unsigned AXI_BYTE_OFFSET_WIDTH =
      (MEM_AXI_DATA_BYTE_COUNT > 1) ? $clog2(MEM_AXI_DATA_BYTE_COUNT) : 1;

  axi4_addr_t current_word_addr_q;
  axi4_addr_t current_word_addr_d;
  int unsigned current_word_bit_offset;

  logic refill_req_handshake;
  logic axi_read_address_handshake;
  logic axi_read_data_handshake;
  logic response_has_access_fault;

  assign refill_req_handshake       = refill_req_valid_i && refill_req_ready_o;
  assign axi_read_address_handshake = axi_manager_o.ar_valid && axi_manager_i.ar_ready;
  assign axi_read_data_handshake    = axi_manager_i.r_valid && axi_manager_o.r_ready;
  assign response_has_access_fault  =
      (axi_manager_i.r.resp != AXI4_RESP_OKAY) &&
      (axi_manager_i.r.resp != AXI4_RESP_EXOKAY);

  // AXI允许在较宽数据总线上发出窄传输。此时有效word位于由地址低位指定的byte lane，
  // 不能直接把整个RDATA转换成cache word。current_word_addr_q同时用于发出AR地址和
  // 选择返回lane，每接受一个非末beat后按cache word宽度递增。
  always_comb begin
    current_word_bit_offset = int'(current_word_addr_q[AXI_BYTE_OFFSET_WIDTH-1:0]) * 8;
  end

  // 第一段：组合输出。写通道在I-cache adapter中永久关闭。
  always_comb begin
    refill_req_ready_o  = state_q == REFILL_IDLE;
    refill_resp_o       = '0;
    refill_resp_valid_o = 1'b0;
    axi_manager_o       = '0;

    unique case (state_q)
      REFILL_SEND_READ_ADDRESS: begin
        axi_manager_o.ar.addr  = current_word_addr_q;
        axi_manager_o.ar.id    = READ_TRANSACTION_ID;
        axi_manager_o.ar.len   = 8'(refill_transaction_context_q.requested_word_count - 1'b1);
        axi_manager_o.ar.size  = 3'($clog2(ICACHE_FETCH_BYTES));
        axi_manager_o.ar.burst = AXI4_BURST_INCR;
        axi_manager_o.ar_valid = 1'b1;
      end

      REFILL_RECEIVE_READ_DATA: begin
        refill_resp_o.word_data =
            icache_fetch_data_t'(axi_manager_i.r.data >> current_word_bit_offset);
        refill_resp_o.word_index        = received_word_index_q;
        refill_resp_o.last_word         = axi_manager_i.r.last;
        refill_resp_o.access_fault      = response_has_access_fault;
        refill_resp_o.transaction_index = refill_transaction_context_q.transaction_index;
        refill_resp_valid_o             = axi_manager_i.r_valid;
        axi_manager_o.r_ready           = refill_resp_ready_i;
      end

      default: ;
    endcase
  end

  // 第二段：事务状态和beat位置。单word uncached fetch仍使用LEN=0的INCR事务。
  always_comb begin
    state_d                      = state_q;
    refill_transaction_context_d = refill_transaction_context_q;
    received_word_index_d        = received_word_index_q;
    current_word_addr_d          = current_word_addr_q;

    unique case (state_q)
      REFILL_IDLE: begin
        if (refill_req_handshake) begin
          refill_transaction_context_d.requested_word_count = refill_req_i.requested_word_count;
          refill_transaction_context_d.transaction_index    = refill_req_i.transaction_index;
          if (refill_req_i.requested_word_count == icache_refill_word_count_t'(1)) begin
            received_word_index_d = refill_req_i.critical_word_index;
            current_word_addr_d   =
                refill_req_i.line_base_addr +
                MEM_AXI_ADDR_WIDTH'(refill_req_i.critical_word_index * ICACHE_FETCH_BYTES);
          end else begin
            received_word_index_d = '0;
            current_word_addr_d   = refill_req_i.line_base_addr;
          end
          state_d = REFILL_SEND_READ_ADDRESS;
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
            state_d = REFILL_IDLE;
          end else begin
            received_word_index_d = received_word_index_q + icache_word_index_t'(1);
            // AR 地址已被接收；此后只推进 RDATA 的 byte lane，地址高位保持。
            current_word_addr_d[AXI_BYTE_OFFSET_WIDTH-1:0] =
                current_word_addr_q[AXI_BYTE_OFFSET_WIDTH-1:0] +
                AXI_BYTE_OFFSET_WIDTH'(ICACHE_FETCH_BYTES);
          end
        end
      end

      default: begin
        state_d = REFILL_IDLE;
      end
    endcase
  end

  // 第三段：状态、请求身份和beat计数分别更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      state_q <= REFILL_IDLE;
    else
      state_q <= state_d;
  end

  // payload寄存器只在state_q赋予其语义后读取，因此不需要复位或在事务结束时清零。
  // 这会综合成普通数据触发器，而不是为无效payload增加异步复位网络。
  always_ff @(posedge clk_i) begin
    refill_transaction_context_q <= refill_transaction_context_d;
  end

  always_ff @(posedge clk_i) begin
    received_word_index_q <= received_word_index_d;
    current_word_addr_q   <= current_word_addr_d;
  end

`ifndef SYNTHESIS
  initial begin
    assert (ICACHE_FETCH_BYTES <= MEM_AXI_DATA_BYTE_COUNT)
    else $fatal(1, "I-cache refill word cannot exceed one AXI beat");
    assert ((ICACHE_FETCH_BYTES & (ICACHE_FETCH_BYTES - 1)) == 0)
    else $fatal(1, "I-cache fetch byte count must be a power of two");
    assert ((MEM_AXI_DATA_BYTE_COUNT & (MEM_AXI_DATA_BYTE_COUNT - 1)) == 0)
    else $fatal(1, "AXI data byte count must be a power of two");
  end
`endif

endmodule
