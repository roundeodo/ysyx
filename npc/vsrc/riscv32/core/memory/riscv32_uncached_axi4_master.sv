// Core本地访存协议到AXI4的阻塞式宽度adapter。
// 一个core请求可以拆成多个AXI beat；adapter只在全部beat结束后返回一个本地响应。
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

  localparam int unsigned CORE_BYTE_OFFSET_WIDTH =
      (CORE_DATA_BYTE_COUNT > 1) ? $clog2(CORE_DATA_BYTE_COUNT) : 1;
  localparam int unsigned MAX_AXI_BEAT_COUNT =
      (CORE_DATA_BYTE_COUNT + MEM_AXI_DATA_BYTE_COUNT - 1) / MEM_AXI_DATA_BYTE_COUNT;
  localparam int unsigned AXI_BEAT_INDEX_WIDTH =
      (MAX_AXI_BEAT_COUNT > 1) ? $clog2(MAX_AXI_BEAT_COUNT) : 1;
  localparam int unsigned AXI_BYTE_OFFSET_WIDTH =
      (MEM_AXI_DATA_BYTE_COUNT > 1) ? $clog2(MEM_AXI_DATA_BYTE_COUNT) : 1;
  localparam int unsigned AXI_MAX_TRANSFER_SIZE = $clog2(MEM_AXI_DATA_BYTE_COUNT);

  typedef logic [AXI_BEAT_INDEX_WIDTH-1:0] axi_beat_index_t;

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

  axi_beat_index_t read_beat_index_q;
  axi_beat_index_t read_beat_index_d;
  axi_beat_index_t write_beat_index_q;
  axi_beat_index_t write_beat_index_d;
  logic            write_address_pending_q;
  logic            write_address_pending_d;
  logic            write_data_pending_q;
  logic            write_data_pending_d;
  logic            read_access_fault_q;
  logic            read_access_fault_d;

  logic [CORE_BYTE_OFFSET_WIDTH-1:0] first_core_byte_offset;
  axi_beat_index_t                   first_axi_slice_index;
  logic [7:0]                        axi_burst_length;
  logic [2:0]                        axi_transfer_size;
  axi_beat_index_t                   current_read_slice_index;
  axi_beat_index_t                   current_write_slice_index;
  logic                              current_write_beat_is_last;

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

  // 本地数据按core beat对齐；根据请求地址选择它落入的第一个AXI数据切片。
  // 例如64位core在地址+4执行LW时，选择core_data[63:32]并生成一个32位AXI beat。
  always_comb begin
    first_core_byte_offset = data_memory_req_q.addr[CORE_BYTE_OFFSET_WIDTH-1:0];
    first_axi_slice_index = axi_beat_index_t'(
        first_core_byte_offset >> AXI_BYTE_OFFSET_WIDTH
    );
    current_read_slice_index  = first_axi_slice_index + read_beat_index_q;
    current_write_slice_index = first_axi_slice_index + write_beat_index_q;

    if (int'(data_memory_req_q.size) > AXI_MAX_TRANSFER_SIZE) begin
      axi_transfer_size = 3'(AXI_MAX_TRANSFER_SIZE);
      axi_burst_length = 8'((1 << (int'(data_memory_req_q.size) -
                                   AXI_MAX_TRANSFER_SIZE)) - 1);
    end else begin
      axi_transfer_size = 3'(data_memory_req_q.size);
      axi_burst_length  = 8'd0;
    end

    current_write_beat_is_last =
        write_beat_index_q == axi_beat_index_t'(axi_burst_length);
  end

  // 第一段：组合输出。valid被阻塞时，payload只依赖锁存请求和beat索引，因此保持稳定。
  always_comb begin
    data_memory_req_ready_o  = state_q == UNCACHED_IDLE;
    data_memory_resp_o       = data_memory_resp_q;
    data_memory_resp_valid_o = state_q == UNCACHED_HOLD_LOCAL_RESPONSE;
    axi_manager_o            = '0;

    unique case (state_q)
      UNCACHED_SEND_READ_ADDRESS: begin
        axi_manager_o.ar.addr  = data_memory_req_q.addr;
        axi_manager_o.ar.id    = READ_TRANSACTION_ID;
        axi_manager_o.ar.len   = axi_burst_length;
        axi_manager_o.ar.size  = axi_transfer_size;
        axi_manager_o.ar.burst = AXI4_BURST_INCR;
        axi_manager_o.ar_valid = 1'b1;
      end

      UNCACHED_RECEIVE_READ_DATA: axi_manager_o.r_ready = 1'b1;

      UNCACHED_SEND_WRITE_ADDRESS_DATA: begin
        axi_manager_o.aw.addr  = data_memory_req_q.addr;
        axi_manager_o.aw.id    = WRITE_TRANSACTION_ID;
        axi_manager_o.aw.len   = axi_burst_length;
        axi_manager_o.aw.size  = axi_transfer_size;
        axi_manager_o.aw.burst = AXI4_BURST_INCR;
        axi_manager_o.aw_valid = write_address_pending_q;

        axi_manager_o.w.data = data_memory_req_q.write_data[
            current_write_slice_index * MEM_AXI_DATA_WIDTH +: MEM_AXI_DATA_WIDTH
        ];
        axi_manager_o.w.strb = data_memory_req_q.byte_strobe[
            current_write_slice_index * MEM_AXI_DATA_BYTE_COUNT +: MEM_AXI_DATA_BYTE_COUNT
        ];
        axi_manager_o.w.last  = current_write_beat_is_last;
        axi_manager_o.w_valid = write_data_pending_q;
      end

      UNCACHED_RECEIVE_WRITE_RESPONSE: axi_manager_o.b_ready = 1'b1;

      default: ;
    endcase
  end

  // 第二段：读数据逐beat写入对应core切片；任一R beat报错都会汇总到最终唯一的
  // 本地响应。写地址与写数据保持独立握手，W可以连续发送多个beat。
  always_comb begin
    state_d                 = state_q;
    data_memory_req_d       = data_memory_req_q;
    data_memory_resp_d      = data_memory_resp_q;
    read_beat_index_d       = read_beat_index_q;
    write_beat_index_d      = write_beat_index_q;
    write_address_pending_d = write_address_pending_q;
    write_data_pending_d    = write_data_pending_q;
    read_access_fault_d     = read_access_fault_q;

    unique case (state_q)
      UNCACHED_IDLE: begin
        if (local_req_handshake) begin
          data_memory_req_d   = data_memory_req_i;
          data_memory_resp_d  = '0;
          read_beat_index_d   = '0;
          write_beat_index_d  = '0;
          read_access_fault_d = 1'b0;
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
          data_memory_resp_d.read_data[
              current_read_slice_index * MEM_AXI_DATA_WIDTH +: MEM_AXI_DATA_WIDTH
          ] = axi_manager_i.r.data;
          read_access_fault_d = read_access_fault_q || read_response_has_access_fault;

          if (axi_manager_i.r.last) begin
            data_memory_resp_d.access_fault =
                read_access_fault_q || read_response_has_access_fault;
            data_memory_resp_d.transaction_id = data_memory_req_q.transaction_id;
            state_d = UNCACHED_HOLD_LOCAL_RESPONSE;
          end else begin
            read_beat_index_d = read_beat_index_q + axi_beat_index_t'(1);
          end
        end
      end

      UNCACHED_SEND_WRITE_ADDRESS_DATA: begin
        if (axi_write_address_handshake) write_address_pending_d = 1'b0;
        if (axi_write_data_handshake) begin
          if (current_write_beat_is_last) begin
            write_data_pending_d = 1'b0;
          end else begin
            write_beat_index_d = write_beat_index_q + axi_beat_index_t'(1);
          end
        end

        if ((!write_address_pending_q || axi_write_address_handshake) &&
            (!write_data_pending_q ||
             (axi_write_data_handshake && current_write_beat_is_last))) begin
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
        read_beat_index_d       = '0;
        write_beat_index_d      = '0;
        write_address_pending_d = 1'b0;
        write_data_pending_d    = 1'b0;
        read_access_fault_d     = 1'b0;
      end
    endcase
  end

  // 第三段：按职责分组更新，便于分别检查事务状态、payload和通道进度。
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
      read_beat_index_q       <= '0;
      write_beat_index_q      <= '0;
      write_address_pending_q <= 1'b0;
      write_data_pending_q    <= 1'b0;
      read_access_fault_q     <= 1'b0;
    end else begin
      read_beat_index_q       <= read_beat_index_d;
      write_beat_index_q      <= write_beat_index_d;
      write_address_pending_q <= write_address_pending_d;
      write_data_pending_q    <= write_data_pending_d;
      read_access_fault_q     <= read_access_fault_d;
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (CORE_DATA_WIDTH >= MEM_AXI_DATA_WIDTH)
      else $fatal(1, "uncached adapter requires CORE_DATA_WIDTH >= MEM_AXI_DATA_WIDTH");
    assert ((CORE_DATA_WIDTH % MEM_AXI_DATA_WIDTH) == 0)
      else $fatal(1, "core/AXI data-width ratio must be an integer");
    assert ((MEM_AXI_DATA_BYTE_COUNT & (MEM_AXI_DATA_BYTE_COUNT - 1)) == 0)
      else $fatal(1, "AXI data byte count must be a power of two");
  end

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
`endif

endmodule
