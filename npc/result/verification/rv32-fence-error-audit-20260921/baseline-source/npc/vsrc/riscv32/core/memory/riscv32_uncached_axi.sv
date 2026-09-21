// Core本地访存协议到memory AXI4的阻塞式单beat adapter。
// Core数据口与正式memory AXI保持同宽；ysyxSoC的32位限制只在system wrapper处理。
module riscv32_uncached_axi
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
  import riscv32_axi4_pkg::*;
#(
    parameter logic [MEM_AXI_ID_WIDTH-1:0] READ_TRANSACTION_ID  = MEM_AXI_ID_WIDTH'(1),
    parameter logic [MEM_AXI_ID_WIDTH-1:0] WRITE_TRANSACTION_ID = MEM_AXI_ID_WIDTH'(2)
) (
    input  logic clk_i,
    input  logic rst_ni,

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
    UNCACHED_RECEIVE_WRITE_RESPONSE
  } uncached_adapter_state_e;

  uncached_adapter_state_e state_q;
  uncached_adapter_state_e state_d;

  // cmd只用于IDLE时选择读/写状态，进入事务后不再保存。其余字段是AXI payload和
  // 本地response身份真正依赖的最小上下文，避免锁存整个语义请求。
  typedef struct packed {
    phys_addr_t        addr;
    mem_size_e         size;
    core_data_t        write_data;
    core_byte_strobe_t byte_strobe;
    mem_txn_id_t       transaction_id;
  } uncached_request_context_t;

  uncached_request_context_t request_context_q;
  uncached_request_context_t request_context_d;

  logic write_address_pending_q;
  logic write_address_pending_d;
  logic write_data_pending_q;
  logic write_data_pending_d;

  logic local_req_handshake;
  logic axi_read_address_handshake;
  logic axi_read_data_handshake;
  logic axi_write_address_handshake;
  logic axi_write_data_handshake;
  logic axi_write_response_handshake;
  logic read_response_has_access_fault;
  logic write_response_has_access_fault;
  logic new_request_window_open;
  logic hold_read_address;
  logic hold_write_payload;

  assign local_req_handshake          = data_memory_req_valid_i && data_memory_req_ready_o;
  assign axi_read_address_handshake   = axi_manager_o.ar_valid && axi_manager_i.ar_ready;
  assign axi_read_data_handshake      = axi_manager_i.r_valid && axi_manager_o.r_ready;
  assign axi_write_address_handshake  = axi_manager_o.aw_valid && axi_manager_i.aw_ready;
  assign axi_write_data_handshake     = axi_manager_o.w_valid && axi_manager_i.w_ready;
  assign axi_write_response_handshake = axi_manager_i.b_valid && axi_manager_o.b_ready;
  assign read_response_has_access_fault =
      (axi_manager_i.r.resp != AXI4_RESP_OKAY) &&
      (axi_manager_i.r.resp != AXI4_RESP_EXOKAY);
  assign write_response_has_access_fault =
      (axi_manager_i.b.resp != AXI4_RESP_OKAY) &&
      (axi_manager_i.b.resp != AXI4_RESP_EXOKAY);
  assign new_request_window_open = (state_q == UNCACHED_IDLE) ||
      ((state_q == UNCACHED_RECEIVE_READ_DATA) && axi_read_data_handshake &&
       !read_response_has_access_fault) ||
      ((state_q == UNCACHED_RECEIVE_WRITE_RESPONSE) && axi_write_response_handshake &&
       !write_response_has_access_fault);
  assign hold_read_address  = state_q == UNCACHED_SEND_READ_ADDRESS;
  assign hold_write_payload = state_q == UNCACHED_SEND_WRITE_ADDRESS_DATA;

  // 第一段：空闲时直接展示请求，未握手的通道在沿后由上下文继续驱动。
  // AW/W 各自记账；响应由 target 保持，直到本地消费者接收。
  always_comb begin
    data_memory_req_ready_o  = new_request_window_open;
    data_memory_resp_o       = '0;
    data_memory_resp_valid_o = 1'b0;
    axi_manager_o            = '0;

    // 地址和数据只按寄存状态选源，不用 valid 清零整份 payload。
    // 空闲直通受阻后，沿上捕获的上下文继续驱动相同值；是否发出由下面的 valid 决定。
    axi_manager_o.ar.addr = hold_read_address ? request_context_q.addr : data_memory_req_i.addr;
    axi_manager_o.ar.id    = READ_TRANSACTION_ID;
    axi_manager_o.ar.len   = 8'd0;
    axi_manager_o.ar.size  = hold_read_address ? 3'(request_context_q.size) : 3'(data_memory_req_i.size);
    axi_manager_o.ar.burst = AXI4_BURST_INCR;
    axi_manager_o.aw       = axi_manager_o.ar;
    axi_manager_o.aw.addr = hold_write_payload ? request_context_q.addr : data_memory_req_i.addr;
    axi_manager_o.aw.size = hold_write_payload ? 3'(request_context_q.size) : 3'(data_memory_req_i.size);
    axi_manager_o.aw.id    = WRITE_TRANSACTION_ID;
    axi_manager_o.w.data = hold_write_payload ?
        axi4_data_t'(request_context_q.write_data) : axi4_data_t'(data_memory_req_i.write_data);
    axi_manager_o.w.strb = hold_write_payload ?
        axi4_strb_t'(request_context_q.byte_strobe) : axi4_strb_t'(data_memory_req_i.byte_strobe);
    axi_manager_o.w.last   = 1'b1;

    unique case (state_q)
      UNCACHED_SEND_READ_ADDRESS: begin
        axi_manager_o.ar_valid = 1'b1;
      end

      UNCACHED_RECEIVE_READ_DATA: begin
        data_memory_resp_o.read_data      = core_data_t'(axi_manager_i.r.data);
        data_memory_resp_o.access_fault   = read_response_has_access_fault;
        data_memory_resp_o.transaction_id = request_context_q.transaction_id;
        data_memory_resp_valid_o          = axi_manager_i.r_valid;
        axi_manager_o.r_ready             = data_memory_resp_ready_i;
      end

      UNCACHED_SEND_WRITE_ADDRESS_DATA: begin
        axi_manager_o.aw_valid = write_address_pending_q;
        axi_manager_o.w_valid = write_data_pending_q;
      end

      UNCACHED_RECEIVE_WRITE_RESPONSE: begin
        data_memory_resp_o.read_data      = '0;
        data_memory_resp_o.access_fault   = write_response_has_access_fault;
        data_memory_resp_o.transaction_id = request_context_q.transaction_id;
        data_memory_resp_valid_o          = axi_manager_i.b_valid;
        axi_manager_o.b_ready             = data_memory_resp_ready_i;
      end

      default: ;
    endcase

    // 旧响应仍使用 request_context_q；新请求独立驱动地址/数据通道。
    if (new_request_window_open) begin
      axi_manager_o.ar_valid = data_memory_req_valid_i && data_memory_req_i.cmd == MEM_CMD_LOAD;
      axi_manager_o.aw_valid = data_memory_req_valid_i && data_memory_req_i.cmd != MEM_CMD_LOAD;
      axi_manager_o.w_valid  = axi_manager_o.aw_valid;
    end
  end

  // 第二段：状态转换与下一值。一个本地请求严格对应一个AXI事务和一个本地响应。
  always_comb begin
    state_d                 = state_q;
    request_context_d       = request_context_q;
    write_address_pending_d = write_address_pending_q;
    write_data_pending_d    = write_data_pending_q;

    unique case (state_q)
      UNCACHED_IDLE: ;

      UNCACHED_SEND_READ_ADDRESS: begin
        if (axi_read_address_handshake)
          state_d = UNCACHED_RECEIVE_READ_DATA;
      end

      UNCACHED_RECEIVE_READ_DATA: begin
        if (axi_read_data_handshake) begin
          state_d = UNCACHED_IDLE;
        end
      end

      UNCACHED_SEND_WRITE_ADDRESS_DATA: begin
        if (axi_write_address_handshake)
          write_address_pending_d = 1'b0;
        if (axi_write_data_handshake)
          write_data_pending_d = 1'b0;

        if ((!write_address_pending_q || axi_write_address_handshake) &&
            (!write_data_pending_q || axi_write_data_handshake)) begin
          state_d = UNCACHED_RECEIVE_WRITE_RESPONSE;
        end
      end

      UNCACHED_RECEIVE_WRITE_RESPONSE: begin
        if (axi_write_response_handshake) begin
          state_d = UNCACHED_IDLE;
        end
      end

      default: begin
        state_d                 = UNCACHED_IDLE;
        write_address_pending_d = 1'b0;
        write_data_pending_d    = 1'b0;
      end
    endcase

    // 交接拍先完成旧响应，再用新请求决定下一状态和协议进度。
    if (local_req_handshake) begin
      request_context_d.addr           = data_memory_req_i.addr;
      request_context_d.size           = data_memory_req_i.size;
      request_context_d.write_data     = data_memory_req_i.write_data;
      request_context_d.byte_strobe    = data_memory_req_i.byte_strobe;
      request_context_d.transaction_id = data_memory_req_i.transaction_id;
      if (data_memory_req_i.cmd == MEM_CMD_LOAD) begin
        state_d = axi_read_address_handshake ?
            UNCACHED_RECEIVE_READ_DATA : UNCACHED_SEND_READ_ADDRESS;
      end else begin
        write_address_pending_d = !axi_write_address_handshake;
        write_data_pending_d    = !axi_write_data_handshake;
        state_d = (axi_write_address_handshake && axi_write_data_handshake) ?
            UNCACHED_RECEIVE_WRITE_RESPONSE : UNCACHED_SEND_WRITE_ADDRESS_DATA;
      end
    end
  end

  // 第三段：状态、紧凑请求上下文和独立write channel进度分别更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      state_q <= UNCACHED_IDLE;
    else
      state_q <= state_d;
  end

  // payload只在非IDLE状态读取，复位时无需给数据位增加异步清零网络。
  always_ff @(posedge clk_i) begin
    request_context_q <= request_context_d;
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
      else
        $fatal(1, "core and memory AXI must have the same data width");
    assert ((MEM_AXI_DATA_BYTE_COUNT & (MEM_AXI_DATA_BYTE_COUNT - 1)) == 0)
      else
        $fatal(1, "AXI data byte count must be a power of two");
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
