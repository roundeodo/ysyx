// D-cache line refill/writeback协议到memory AXI4的边界adapter。
//
// 一个refill对应一个INCR读burst，一个writeback对应一个INCR写burst。读写请求在IDLE
// 当拍直接展示到AXI，消除固定发送空拍；AXI反压后由寄存上下文保持payload稳定。
module riscv32_dcache_line_axi4_master
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
#(
    parameter logic [MEM_AXI_ID_WIDTH-1:0] READ_TRANSACTION_ID  = MEM_AXI_ID_WIDTH'(1),
    parameter logic [MEM_AXI_ID_WIDTH-1:0] WRITE_TRANSACTION_ID = MEM_AXI_ID_WIDTH'(2)
) (
    input logic clk_i,
    input logic rst_ni,

    input  dcache_refill_req_t refill_req_i,
    input  logic               refill_req_valid_i,
    output logic               refill_req_ready_o,
    output dcache_refill_resp_t refill_resp_o,
    output logic                refill_resp_valid_o,
    input  logic                refill_resp_ready_i,

    input  dcache_writeback_req_t writeback_req_i,
    input  logic                  writeback_req_valid_i,
    output logic                  writeback_req_ready_o,
    output dcache_writeback_resp_t writeback_resp_o,
    output logic                   writeback_resp_valid_o,
    input  logic                   writeback_resp_ready_i,

    output axi4_manager_to_target_t axi_manager_o,
    input  axi4_target_to_manager_t axi_manager_i
);

  typedef enum logic [2:0] {
    LINE_AXI_IDLE,
    LINE_AXI_SEND_REFILL_ADDRESS,
    LINE_AXI_RECEIVE_REFILL_DATA,
    LINE_AXI_SEND_WRITEBACK_ADDRESS_DATA,
    LINE_AXI_RECEIVE_WRITEBACK_RESPONSE
  } line_axi_state_e;

  line_axi_state_e state_q, state_d;
  dcache_refill_req_t refill_context_q, refill_context_d;
  dcache_writeback_req_t writeback_context_q, writeback_context_d;
  dcache_word_index_t transferred_word_index_q, transferred_word_index_d;
  logic write_address_pending_q, write_address_pending_d;
  logic write_data_pending_q, write_data_pending_d;

  logic refill_req_handshake;
  logic writeback_req_handshake;
  logic axi_read_address_handshake;
  logic axi_read_data_handshake;
  logic axi_write_address_handshake;
  logic axi_write_data_handshake;
  logic axi_write_response_handshake;
  logic read_access_fault;
  logic write_access_fault;
  logic selected_idle_refill;

  assign selected_idle_refill = refill_req_valid_i && !writeback_req_valid_i;
  assign refill_req_ready_o = (state_q == LINE_AXI_IDLE) && !writeback_req_valid_i;
  assign writeback_req_ready_o = state_q == LINE_AXI_IDLE;
  assign refill_req_handshake = refill_req_valid_i && refill_req_ready_o;
  assign writeback_req_handshake = writeback_req_valid_i && writeback_req_ready_o;
  assign axi_read_address_handshake = axi_manager_o.ar_valid && axi_manager_i.ar_ready;
  assign axi_read_data_handshake = axi_manager_i.r_valid && axi_manager_o.r_ready;
  assign axi_write_address_handshake = axi_manager_o.aw_valid && axi_manager_i.aw_ready;
  assign axi_write_data_handshake = axi_manager_o.w_valid && axi_manager_i.w_ready;
  assign axi_write_response_handshake = axi_manager_i.b_valid && axi_manager_o.b_ready;
  assign read_access_fault = (axi_manager_i.r.resp != AXI4_RESP_OKAY) &&
                             (axi_manager_i.r.resp != AXI4_RESP_EXOKAY);
  assign write_access_fault = (axi_manager_i.b.resp != AXI4_RESP_OKAY) &&
                              (axi_manager_i.b.resp != AXI4_RESP_EXOKAY);

  always_comb begin
    axi_manager_o = '0;
    refill_resp_o = '0;
    refill_resp_valid_o = 1'b0;
    writeback_resp_o = '0;
    writeback_resp_valid_o = 1'b0;

    unique case (state_q)
      LINE_AXI_IDLE: begin
        if (writeback_req_valid_i) begin
          axi_manager_o.aw.addr = writeback_req_i.line_base_addr;
          axi_manager_o.aw.id = WRITE_TRANSACTION_ID;
          axi_manager_o.aw.len = 8'(DCACHE_WORDS_PER_LINE - 1);
          axi_manager_o.aw.size = 3'($clog2(DCACHE_WORD_BYTES));
          axi_manager_o.aw.burst = AXI4_BURST_INCR;
          axi_manager_o.aw_valid = 1'b1;
          axi_manager_o.w.data = axi4_data_t'(
              writeback_req_i.line_data[0+:CORE_DATA_WIDTH]
          );
          axi_manager_o.w.strb = '1;
          axi_manager_o.w.last = DCACHE_WORDS_PER_LINE == 1;
          axi_manager_o.w_valid = 1'b1;
        end else if (selected_idle_refill) begin
          axi_manager_o.ar.addr = refill_req_i.line_base_addr;
          axi_manager_o.ar.id = READ_TRANSACTION_ID;
          axi_manager_o.ar.len = 8'(DCACHE_WORDS_PER_LINE - 1);
          axi_manager_o.ar.size = 3'($clog2(DCACHE_WORD_BYTES));
          axi_manager_o.ar.burst = AXI4_BURST_INCR;
          axi_manager_o.ar_valid = 1'b1;
        end
      end

      LINE_AXI_SEND_REFILL_ADDRESS: begin
        axi_manager_o.ar.addr = refill_context_q.line_base_addr;
        axi_manager_o.ar.id = READ_TRANSACTION_ID;
        axi_manager_o.ar.len = 8'(DCACHE_WORDS_PER_LINE - 1);
        axi_manager_o.ar.size = 3'($clog2(DCACHE_WORD_BYTES));
        axi_manager_o.ar.burst = AXI4_BURST_INCR;
        axi_manager_o.ar_valid = 1'b1;
      end

      LINE_AXI_RECEIVE_REFILL_DATA: begin
        refill_resp_o.word_data = core_data_t'(axi_manager_i.r.data);
        refill_resp_o.word_index = transferred_word_index_q;
        refill_resp_o.last_word = axi_manager_i.r.last;
        refill_resp_o.access_fault = read_access_fault;
        refill_resp_o.transaction_id = refill_context_q.transaction_id;
        refill_resp_valid_o = axi_manager_i.r_valid;
        axi_manager_o.r_ready = refill_resp_ready_i;
      end

      LINE_AXI_SEND_WRITEBACK_ADDRESS_DATA: begin
        axi_manager_o.aw.addr = writeback_context_q.line_base_addr;
        axi_manager_o.aw.id = WRITE_TRANSACTION_ID;
        axi_manager_o.aw.len = 8'(DCACHE_WORDS_PER_LINE - 1);
        axi_manager_o.aw.size = 3'($clog2(DCACHE_WORD_BYTES));
        axi_manager_o.aw.burst = AXI4_BURST_INCR;
        axi_manager_o.aw_valid = write_address_pending_q;
        axi_manager_o.w.data = axi4_data_t'(
            writeback_context_q.line_data[
                int'(transferred_word_index_q)*CORE_DATA_WIDTH+:CORE_DATA_WIDTH
            ]
        );
        axi_manager_o.w.strb = '1;
        axi_manager_o.w.last =
            transferred_word_index_q == dcache_word_index_t'(DCACHE_WORDS_PER_LINE - 1);
        axi_manager_o.w_valid = write_data_pending_q;
      end

      LINE_AXI_RECEIVE_WRITEBACK_RESPONSE: begin
        writeback_resp_o.access_fault = write_access_fault;
        writeback_resp_o.transaction_id = writeback_context_q.transaction_id;
        writeback_resp_valid_o = axi_manager_i.b_valid;
        axi_manager_o.b_ready = writeback_resp_ready_i;
      end

      default: ;
    endcase
  end

  always_comb begin
    state_d = state_q;
    refill_context_d = refill_context_q;
    writeback_context_d = writeback_context_q;
    transferred_word_index_d = transferred_word_index_q;
    write_address_pending_d = write_address_pending_q;
    write_data_pending_d = write_data_pending_q;

    unique case (state_q)
      LINE_AXI_IDLE: begin
        transferred_word_index_d = '0;
        if (writeback_req_handshake) begin
          writeback_context_d = writeback_req_i;
          write_address_pending_d = !axi_write_address_handshake;
          if (axi_write_data_handshake) begin
            write_data_pending_d = DCACHE_WORDS_PER_LINE != 1;
            transferred_word_index_d = dcache_word_index_t'(1);
          end else begin
            write_data_pending_d = 1'b1;
          end
          state_d = (!write_address_pending_d && !write_data_pending_d) ?
                    LINE_AXI_RECEIVE_WRITEBACK_RESPONSE :
                    LINE_AXI_SEND_WRITEBACK_ADDRESS_DATA;
        end else if (refill_req_handshake) begin
          refill_context_d = refill_req_i;
          state_d = axi_read_address_handshake ? LINE_AXI_RECEIVE_REFILL_DATA :
                                                 LINE_AXI_SEND_REFILL_ADDRESS;
        end
      end

      LINE_AXI_SEND_REFILL_ADDRESS: begin
        if (axi_read_address_handshake) state_d = LINE_AXI_RECEIVE_REFILL_DATA;
      end

      LINE_AXI_RECEIVE_REFILL_DATA: begin
        if (axi_read_data_handshake) begin
          if (axi_manager_i.r.last) begin
            state_d = LINE_AXI_IDLE;
          end else begin
            transferred_word_index_d = transferred_word_index_q + dcache_word_index_t'(1);
          end
        end
      end

      LINE_AXI_SEND_WRITEBACK_ADDRESS_DATA: begin
        if (axi_write_address_handshake) write_address_pending_d = 1'b0;
        if (axi_write_data_handshake) begin
          if (axi_manager_o.w.last) begin
            write_data_pending_d = 1'b0;
          end else begin
            transferred_word_index_d = transferred_word_index_q + dcache_word_index_t'(1);
          end
        end
        if ((!write_address_pending_q || axi_write_address_handshake) &&
            (!write_data_pending_q || (axi_write_data_handshake && axi_manager_o.w.last))) begin
          state_d = LINE_AXI_RECEIVE_WRITEBACK_RESPONSE;
        end
      end

      LINE_AXI_RECEIVE_WRITEBACK_RESPONSE: begin
        if (axi_write_response_handshake) state_d = LINE_AXI_IDLE;
      end

      default: state_d = LINE_AXI_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= LINE_AXI_IDLE;
    else state_q <= state_d;
  end

  always_ff @(posedge clk_i) begin
    refill_context_q <= refill_context_d;
    writeback_context_q <= writeback_context_d;
    transferred_word_index_q <= transferred_word_index_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_address_pending_q <= 1'b0;
      write_data_pending_q <= 1'b0;
    end else begin
      write_address_pending_q <= write_address_pending_d;
      write_data_pending_q <= write_data_pending_d;
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (CORE_DATA_WIDTH == MEM_AXI_DATA_WIDTH)
      else $fatal(1, "D-cache word and memory AXI beat widths must match");
    assert ((DCACHE_LINE_BYTES % DCACHE_WORD_BYTES) == 0)
      else $fatal(1, "D-cache line must contain an integer number of AXI beats");
    assert (DCACHE_WORDS_PER_LINE <= 256)
      else $fatal(1, "AXI4 burst length exceeds 256 beats");
  end

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    axi_manager_o.aw_valid && !axi_manager_i.aw_ready |=> $stable(axi_manager_o.aw));
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    axi_manager_o.w_valid && !axi_manager_i.w_ready |=> $stable(axi_manager_o.w));
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    refill_resp_valid_o && !refill_resp_ready_i |=>
      (refill_resp_valid_o && $stable(refill_resp_o)));
`endif

endmodule
