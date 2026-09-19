// Simulation-only UART character sink with a complete AXI4 target interface.
// The device implements one 32-bit TX register at UART_BASE_ADDR. Bursts are
// consumed according to AXI4, but return SLVERR because this register is scalar.
module riscv32_axi4_uart_sim
  import riscv32_addr_map_pkg::*;
  import riscv32_axi4_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    input  axi4_manager_to_target_t uart_axi_i,
    output axi4_target_to_manager_t uart_axi_o
);

  // UART仿真target需要把AW/AR携带的ID返回到B/R channel；它只消费fabric配置，
  // 不应复制一套ID宽度。UART寄存器行为和字符输出逻辑保持不变。

  typedef enum logic {
    READ_ACCEPT_ADDRESS,
    READ_RETURN_DATA
  } read_state_e;

  typedef enum logic [1:0] {
    WRITE_ACCEPT_ADDRESS,
    WRITE_RECEIVE_DATA,
    WRITE_RETURN_RESPONSE
  } write_state_e;

  read_state_e  read_state_q;
  read_state_e  read_state_d;
  write_state_e write_state_q;
  write_state_e write_state_d;

  logic [MEM_AXI_ID_WIDTH-1:0] read_id_q;
  logic [MEM_AXI_ID_WIDTH-1:0] read_id_d;
  logic [7:0]                  read_last_beat_index_q;
  logic [7:0]                  read_last_beat_index_d;
  logic [7:0]                  read_beat_index_q;
  logic [7:0]                  read_beat_index_d;
  axi4_resp_e                  read_response_q;
  axi4_resp_e                  read_response_d;

  logic [MEM_AXI_ID_WIDTH-1:0] write_id_q;
  logic [MEM_AXI_ID_WIDTH-1:0] write_id_d;
  axi4_resp_e                  write_response_q;
  axi4_resp_e                  write_response_d;

  logic read_address_handshake;
  logic read_data_handshake;
  logic write_address_handshake;
  logic write_data_handshake;
  logic write_response_handshake;

  logic       write_character_event;
  logic [7:0] write_character_data;

  assign read_address_handshake   = uart_axi_i.ar_valid && uart_axi_o.ar_ready;
  assign read_data_handshake      = uart_axi_o.r_valid && uart_axi_i.r_ready;
  assign write_address_handshake  = uart_axi_i.aw_valid && uart_axi_o.aw_ready;
  assign write_data_handshake     = uart_axi_i.w_valid && uart_axi_o.w_ready;
  assign write_response_handshake = uart_axi_o.b_valid && uart_axi_i.b_ready;

  // 第一段：AXI4输出。AW出现时允许首个W beat同拍直通。
  always_comb begin
    uart_axi_o = '0;

    unique case (read_state_q)
      READ_ACCEPT_ADDRESS: begin
        uart_axi_o.ar_ready = 1'b1;
      end

      READ_RETURN_DATA: begin
        uart_axi_o.r.data  = '0;
        uart_axi_o.r.id    = read_id_q;
        uart_axi_o.r.resp  = read_response_q;
        uart_axi_o.r.last  = (read_beat_index_q == read_last_beat_index_q);
        uart_axi_o.r_valid = 1'b1;
      end

      default: ;
    endcase

    unique case (write_state_q)
      WRITE_ACCEPT_ADDRESS: begin
        uart_axi_o.aw_ready = 1'b1;
        uart_axi_o.w_ready  = uart_axi_i.aw_valid;
      end

      WRITE_RECEIVE_DATA: begin
        uart_axi_o.w_ready = 1'b1;
      end

      WRITE_RETURN_RESPONSE: begin
        uart_axi_o.b.id    = write_id_q;
        uart_axi_o.b.resp  = write_response_q;
        uart_axi_o.b_valid = 1'b1;
      end

      default: ;
    endcase
  end

  // 第二段：读事务状态。UART读数据固定为0；单拍且访问宽度不超过总线宽度时返回OKAY。
  always_comb begin
    read_state_d           = read_state_q;
    read_id_d              = read_id_q;
    read_last_beat_index_d = read_last_beat_index_q;
    read_beat_index_d      = read_beat_index_q;
    read_response_d        = read_response_q;

    unique case (read_state_q)
      READ_ACCEPT_ADDRESS: begin
        if (read_address_handshake) begin
          read_id_d              = uart_axi_i.ar.id;
          read_last_beat_index_d = uart_axi_i.ar.len;
          read_beat_index_d      = '0;
          if ((uart_axi_i.ar.addr == UART_BASE_ADDR) &&
              (uart_axi_i.ar.len == 8'd0) &&
              (uart_axi_i.ar.size <= 3'd2)) begin
            read_response_d = AXI4_RESP_OKAY;
          end else begin
            read_response_d = AXI4_RESP_SLVERR;
          end
          read_state_d = READ_RETURN_DATA;
        end
      end

      READ_RETURN_DATA: begin
        if (read_data_handshake) begin
          if (uart_axi_o.r.last) begin
            read_state_d = READ_ACCEPT_ADDRESS;
          end else begin
            read_beat_index_d = read_beat_index_q + 1'b1;
          end
        end
      end

      default: read_state_d = READ_ACCEPT_ADDRESS;
    endcase
  end

  // 字符输出只发生在合法单拍事务的W握手拍。WSTRB[0]表示data[7:0]有效。
  always_comb begin
    write_character_event = 1'b0;
    write_character_data  = uart_axi_i.w.data[7:0];

    if (write_data_handshake && uart_axi_i.w.strb[0] &&
        (((write_state_q == WRITE_ACCEPT_ADDRESS) &&
          (uart_axi_i.aw.addr == UART_BASE_ADDR) &&
          (uart_axi_i.aw.len == 8'd0) &&
          (uart_axi_i.aw.size <= 3'd2)) ||
         ((write_state_q == WRITE_RECEIVE_DATA) &&
          (write_response_q == AXI4_RESP_OKAY)))) begin
      write_character_event = 1'b1;
    end
  end

  // 第二段：写事务状态。地址决定响应属性，数据通道推进到WLAST后返回B。
  always_comb begin
    write_state_d    = write_state_q;
    write_id_d       = write_id_q;
    write_response_d = write_response_q;

    unique case (write_state_q)
      WRITE_ACCEPT_ADDRESS: begin
        if (write_address_handshake) begin
          write_id_d = uart_axi_i.aw.id;
          if ((uart_axi_i.aw.addr == UART_BASE_ADDR) &&
              (uart_axi_i.aw.len == 8'd0) &&
              (uart_axi_i.aw.size <= 3'd2)) begin
            write_response_d = AXI4_RESP_OKAY;
          end else begin
            write_response_d = AXI4_RESP_SLVERR;
          end

          if (write_data_handshake && uart_axi_i.w.last) begin
            write_state_d = WRITE_RETURN_RESPONSE;
          end else begin
            write_state_d = WRITE_RECEIVE_DATA;
          end
        end
      end

      WRITE_RECEIVE_DATA: begin
        if (write_data_handshake && uart_axi_i.w.last) begin
          write_state_d = WRITE_RETURN_RESPONSE;
        end
      end

      WRITE_RETURN_RESPONSE: begin
        if (write_response_handshake) begin
          write_state_d = WRITE_ACCEPT_ADDRESS;
        end
      end

      default: write_state_d = WRITE_ACCEPT_ADDRESS;
    endcase
  end

  // 第三段：读通道寄存器更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_state_q           <= READ_ACCEPT_ADDRESS;
      read_id_q              <= '0;
      read_last_beat_index_q <= '0;
      read_beat_index_q      <= '0;
      read_response_q        <= AXI4_RESP_OKAY;
    end else begin
      read_state_q           <= read_state_d;
      read_id_q              <= read_id_d;
      read_last_beat_index_q <= read_last_beat_index_d;
      read_beat_index_q      <= read_beat_index_d;
      read_response_q        <= read_response_d;
    end
  end

  // 第三段：写通道寄存器更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_state_q    <= WRITE_ACCEPT_ADDRESS;
      write_id_q       <= '0;
      write_response_q <= AXI4_RESP_OKAY;
    end else begin
      write_state_q    <= write_state_d;
      write_id_q       <= write_id_d;
      write_response_q <= write_response_d;
    end
  end

  always_ff @(posedge clk_i) begin
    if (write_character_event) begin
      $write("%c", write_character_data);
      $fflush();
    end
  end

endmodule : riscv32_axi4_uart_sim
