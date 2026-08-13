// LSU本地访存协议到完整AXI4单拍事务的边界adapter。
// v1阻塞式地维护一个事务；AW和W独立握手，只有两者都完成后才等待B。
module riscv32_uncached_axi4_master
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
#(
    // 事务ID值可配置，位宽与全局AXI fabric保持一致。
    parameter logic [AXI_ID_WIDTH-1:0] READ_TRANSACTION_ID  = AXI_ID_WIDTH'(1),
    parameter logic [AXI_ID_WIDTH-1:0] WRITE_TRANSACTION_ID = AXI_ID_WIDTH'(2)
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

  data_memory_req_t data_memory_req_q;
  data_memory_req_t data_memory_req_d;
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
  assign axi_read_address_handshake =
      axi_manager_o.ar_valid && axi_manager_i.ar_ready;
  assign axi_read_data_handshake = axi_manager_i.r_valid && axi_manager_o.r_ready;
  assign axi_write_address_handshake =
      axi_manager_o.aw_valid && axi_manager_i.aw_ready;
  assign axi_write_data_handshake = axi_manager_o.w_valid && axi_manager_i.w_ready;
  assign axi_write_response_handshake =
      axi_manager_i.b_valid && axi_manager_o.b_ready;
  assign read_response_has_access_fault =
      (axi_manager_i.r.resp != AXI4_RESP_OKAY) &&
      (axi_manager_i.r.resp != AXI4_RESP_EXOKAY);
  assign write_response_has_access_fault =
      (axi_manager_i.b.resp != AXI4_RESP_OKAY) &&
      (axi_manager_i.b.resp != AXI4_RESP_EXOKAY);

  // 第一段：组合输出。AXI payload始终来自已锁存的本地请求。
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

      UNCACHED_RECEIVE_READ_DATA: begin
        axi_manager_o.r_ready = 1'b1;
      end

      UNCACHED_SEND_WRITE_ADDRESS_DATA: begin
        axi_manager_o.aw.addr  = data_memory_req_q.addr;
        axi_manager_o.aw.id    = WRITE_TRANSACTION_ID;
        axi_manager_o.aw.len   = 8'd0;
        axi_manager_o.aw.size  = 3'(data_memory_req_q.size);
        axi_manager_o.aw.burst = AXI4_BURST_INCR;
        axi_manager_o.aw_valid = write_address_pending_q;

        axi_manager_o.w.data   = data_memory_req_q.write_data;
        axi_manager_o.w.strb   = data_memory_req_q.byte_strobe;
        axi_manager_o.w.last   = 1'b1;
        axi_manager_o.w_valid  = write_data_pending_q;
      end

      UNCACHED_RECEIVE_WRITE_RESPONSE: begin
        axi_manager_o.b_ready = 1'b1;
      end

      default: ;
    endcase
  end

  // 第二段：状态、独立AW/W完成记录和本地response缓冲。
  always_comb begin
    state_d                 = state_q;
    data_memory_req_d       = data_memory_req_q;
    data_memory_resp_d      = data_memory_resp_q;
    write_address_pending_d = write_address_pending_q;
    write_data_pending_d    = write_data_pending_q;

    unique case (state_q)
      UNCACHED_IDLE: begin
        if (local_req_handshake) begin
          data_memory_req_d = data_memory_req_i;
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
        if (axi_read_address_handshake) begin
          state_d = UNCACHED_RECEIVE_READ_DATA;
        end
      end

      UNCACHED_RECEIVE_READ_DATA: begin
        if (axi_read_data_handshake) begin
          data_memory_resp_d.read_data      = axi_manager_i.r.data;
          data_memory_resp_d.access_fault   = read_response_has_access_fault;
          data_memory_resp_d.transaction_id = data_memory_req_q.transaction_id;
          state_d                           = UNCACHED_HOLD_LOCAL_RESPONSE;
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
          data_memory_resp_d.read_data      = '0;
          data_memory_resp_d.access_fault   = write_response_has_access_fault;
          data_memory_resp_d.transaction_id = data_memory_req_q.transaction_id;
          state_d                           = UNCACHED_HOLD_LOCAL_RESPONSE;
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

  // 第三段：按事务状态、请求/响应payload和AW/W进度分组更新。
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

endmodule
