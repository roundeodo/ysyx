// Core本地访存协议到memory AXI4的阻塞式单beat adapter。
// Core数据口与正式memory AXI保持同宽；ysyxSoC的32位限制只在system wrapper处理。
module riscv32_uncached_axi4_master
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
#(
    parameter logic [MEM_AXI_ID_WIDTH-1:0] READ_TRANSACTION_ID  = MEM_AXI_ID_WIDTH'(1),
    parameter logic [MEM_AXI_ID_WIDTH-1:0] WRITE_TRANSACTION_ID = MEM_AXI_ID_WIDTH'(2)
) (
    input logic clk_i,
    input logic rst_ni,

    input  data_memory_req_t data_memory_req_i,
    input  logic             data_memory_req_valid_i,
    output logic             data_memory_req_ready_o,

    output data_memory_resp_t data_memory_resp_o,
    output logic              data_memory_resp_valid_o,
    input  logic              data_memory_resp_ready_i,

    output axi4_manager_to_target_t axi_manager_o,
    input  axi4_target_to_manager_t axi_manager_i
);

  typedef enum logic [2:0] {
    UNCACHED_IDLE,
    UNCACHED_SEND_READ_ADDRESS,
    UNCACHED_RECEIVE_READ_DATA,
    UNCACHED_SEND_WRITE_ADDRESS_DATA,
    UNCACHED_RECEIVE_WRITE_RESPONSE,
    UNCACHED_HOLD_LOCAL_RESPONSE
  } uncached_adapter_state_e;

  uncached_adapter_state_e state_q;
  uncached_adapter_state_e state_d;

  data_memory_req_t  data_memory_req_q;
  data_memory_req_t  data_memory_req_d;
  data_memory_resp_t data_memory_resp_q;
  data_memory_resp_t data_memory_resp_d;

  logic write_address_pending_q;
  logic write_address_pending_d;
  logic write_data_pending_q;
  logic write_data_pending_d;

  logic local_req_handshake;
  logic local_resp_handshake;
  logic axi_read_address_handshake;
  logic axi_read_data_handshake;
  logic axi_write_address_handshake;
  logic axi_write_data_handshake;
  logic axi_write_response_handshake;
  logic read_response_has_access_fault;
  logic write_response_has_access_fault;

  assign local_req_handshake = data_memory_req_valid_i && data_memory_req_ready_o;
  assign local_resp_handshake = data_memory_resp_valid_o && data_memory_resp_ready_i;
  assign axi_read_address_handshake = axi_manager_o.ar_valid && axi_manager_i.ar_ready;
  assign axi_read_data_handshake = axi_manager_i.r_valid && axi_manager_o.r_ready;
  assign axi_write_address_handshake = axi_manager_o.aw_valid && axi_manager_i.aw_ready;
  assign axi_write_data_handshake = axi_manager_o.w_valid && axi_manager_i.w_ready;
  assign axi_write_response_handshake = axi_manager_i.b_valid && axi_manager_o.b_ready;
  assign read_response_has_access_fault =
      (axi_manager_i.r.resp != AXI4_RESP_OKAY) &&
      (axi_manager_i.r.resp != AXI4_RESP_EXOKAY);
  assign write_response_has_access_fault =
      (axi_manager_i.b.resp != AXI4_RESP_OKAY) &&
      (axi_manager_i.b.resp != AXI4_RESP_EXOKAY);

  // 第一段：组合输出。请求先锁存，因此valid受反压时所有AXI payload保持稳定。
  // AW和W分别使用pending位，允许两个独立channel以任意先后顺序完成握手。
  always_comb begin
    data_memory_req_ready_o  = state_q == UNCACHED_IDLE;
    data_memory_resp_o       = data_memory_resp_q;
    data_memory_resp_valid_o = state_q == UNCACHED_HOLD_LOCAL_RESPONSE;
    axi_manager_o            = '0;

    unique case (state_q)
      UNCACHED_SEND_READ_ADDRESS: begin
        axi_manager_o.ar.addr  = data_memory_req_q.addr;
        axi_manager_o.ar.id    = READ_TRANSACTION_ID;
        axi_manager_o.ar.len   = 8'd0;
        axi_manager_o.ar.size  = 3'(data_memory_req_q.size);
        axi_manager_o.ar.burst = AXI4_BURST_INCR;
        axi_manager_o.ar_valid = 1'b1;
      end

      UNCACHED_RECEIVE_READ_DATA: axi_manager_o.r_ready = 1'b1;

      UNCACHED_SEND_WRITE_ADDRESS_DATA: begin
        axi_manager_o.aw.addr  = data_memory_req_q.addr;
        axi_manager_o.aw.id    = WRITE_TRANSACTION_ID;
        axi_manager_o.aw.len   = 8'd0;
        axi_manager_o.aw.size  = 3'(data_memory_req_q.size);
        axi_manager_o.aw.burst = AXI4_BURST_INCR;
        axi_manager_o.aw_valid = write_address_pending_q;

        axi_manager_o.w.data  = axi4_data_t'(data_memory_req_q.write_data);
        axi_manager_o.w.strb  = axi4_strb_t'(data_memory_req_q.byte_strobe);
        axi_manager_o.w.last  = 1'b1;
        axi_manager_o.w_valid = write_data_pending_q;
      end

      UNCACHED_RECEIVE_WRITE_RESPONSE: axi_manager_o.b_ready = 1'b1;

      default: ;
    endcase
  end

  // 第二段：状态转换与下一值。一个本地请求严格对应一个AXI事务和一个本地响应。
  always_comb begin
    state_d                 = state_q;
    data_memory_req_d       = data_memory_req_q;
    data_memory_resp_d      = data_memory_resp_q;
    write_address_pending_d = write_address_pending_q;
    write_data_pending_d    = write_data_pending_q;

    unique case (state_q)
      UNCACHED_IDLE: begin
        if (local_req_handshake) begin
          data_memory_req_d  = data_memory_req_i;
          data_memory_resp_d = '0;
          if (data_memory_req_i.cmd == MEM_CMD_LOAD) begin
            state_d = UNCACHED_SEND_READ_ADDRESS;
          end else begin
            write_address_pending_d = 1'b1;
            write_data_pending_d    = 1'b1;
            state_d                 = UNCACHED_SEND_WRITE_ADDRESS_DATA;
          end
        end
      end

      UNCACHED_SEND_READ_ADDRESS: begin
        if (axi_read_address_handshake) state_d = UNCACHED_RECEIVE_READ_DATA;
      end

      UNCACHED_RECEIVE_READ_DATA: begin
        if (axi_read_data_handshake) begin
          data_memory_resp_d.read_data = core_data_t'(axi_manager_i.r.data);
          data_memory_resp_d.access_fault = read_response_has_access_fault;
          data_memory_resp_d.transaction_id = data_memory_req_q.transaction_id;
          state_d = UNCACHED_HOLD_LOCAL_RESPONSE;
        end
      end

      UNCACHED_SEND_WRITE_ADDRESS_DATA: begin
        if (axi_write_address_handshake) write_address_pending_d = 1'b0;
        if (axi_write_data_handshake) write_data_pending_d = 1'b0;

        if ((!write_address_pending_q || axi_write_address_handshake) &&
            (!write_data_pending_q || axi_write_data_handshake)) begin
          state_d = UNCACHED_RECEIVE_WRITE_RESPONSE;
        end
      end

      UNCACHED_RECEIVE_WRITE_RESPONSE: begin
        if (axi_write_response_handshake) begin
          data_memory_resp_d.read_data = '0;
          data_memory_resp_d.access_fault = write_response_has_access_fault;
          data_memory_resp_d.transaction_id = data_memory_req_q.transaction_id;
          state_d = UNCACHED_HOLD_LOCAL_RESPONSE;
        end
      end

      UNCACHED_HOLD_LOCAL_RESPONSE: begin
        if (local_resp_handshake) begin
          data_memory_req_d       = '0;
          data_memory_resp_d      = '0;
          write_address_pending_d = 1'b0;
          write_data_pending_d    = 1'b0;
          state_d                 = UNCACHED_IDLE;
        end
      end

      default: begin
        state_d                 = UNCACHED_IDLE;
        data_memory_req_d       = '0;
        data_memory_resp_d      = '0;
        write_address_pending_d = 1'b0;
        write_data_pending_d    = 1'b0;
      end
    endcase
  end

  // 第三段：状态、请求/响应payload和独立write channel进度分别更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= UNCACHED_IDLE;
    else state_q <= state_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      data_memory_req_q  <= '0;
      data_memory_resp_q <= '0;
    end else begin
      data_memory_req_q  <= data_memory_req_d;
      data_memory_resp_q <= data_memory_resp_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_address_pending_q <= 1'b0;
      write_data_pending_q    <= 1'b0;
    end else begin
      write_address_pending_q <= write_address_pending_d;
      write_data_pending_q    <= write_data_pending_d;
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (CORE_DATA_WIDTH == MEM_AXI_DATA_WIDTH)
      else $fatal(1, "core and memory AXI must have the same data width");
    assert ((MEM_AXI_DATA_BYTE_COUNT & (MEM_AXI_DATA_BYTE_COUNT - 1)) == 0)
      else $fatal(1, "AXI data byte count must be a power of two");
  end

  property p_write_address_stable_while_blocked;
    @(posedge clk_i) disable iff (!rst_ni)
      axi_manager_o.aw_valid && !axi_manager_i.aw_ready
      |=> $stable(axi_manager_o.aw);
  endproperty
  assert property (p_write_address_stable_while_blocked);

  property p_write_data_stable_while_blocked;
    @(posedge clk_i) disable iff (!rst_ni)
      axi_manager_o.w_valid && !axi_manager_i.w_ready
      |=> $stable(axi_manager_o.w);
  endproperty
  assert property (p_write_data_stable_while_blocked);

  property p_local_response_stable_while_blocked;
    @(posedge clk_i) disable iff (!rst_ni)
      data_memory_resp_valid_o && !data_memory_resp_ready_i
      |=> $stable(data_memory_resp_o);
  endproperty
  assert property (p_local_response_stable_while_blocked);

  property p_single_read_beat;
    @(posedge clk_i) disable iff (!rst_ni)
      axi_read_data_handshake |-> axi_manager_i.r.last;
  endproperty
  assert property (p_single_read_beat);
`endif

endmodule
