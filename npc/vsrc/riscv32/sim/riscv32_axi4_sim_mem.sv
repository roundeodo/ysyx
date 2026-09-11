// 仿真专用AXI4存储器target。CPU和互联只看到标准AXI4事务，DPI访问被限制在本模块。
module riscv32_axi4_sim_mem
  import riscv32_axi4_pkg::*;
#(
    parameter int unsigned IFU_READ_LATENCY = 1,
    parameter int unsigned LSU_READ_LATENCY = 1,
    parameter int unsigned LSU_WRITE_LATENCY = 1,
    parameter int unsigned RANDOM_LATENCY_MAX = 20,
    // 仿真存储器与被测AXI fabric共用地址、数据和ID宽度。
    parameter logic [MEM_AXI_ID_WIDTH-1:0] INSTRUCTION_READ_ID = '0
) (
    input logic clk_i,
    input logic rst_ni,

    input  axi4_manager_to_target_t mem_axi_i,
    output axi4_target_to_manager_t mem_axi_o
);

  import "DPI-C" function longint unsigned pmem_read_data(
      input int unsigned raddr,
      input int transfer_byte_count,
      input int memory_beat_byte_count
  );
  import "DPI-C" function void pmem_write(
      input int unsigned addr,
      input longint unsigned wdata,
      input byte unsigned wmask,
      input int memory_beat_byte_count
  );

  typedef enum logic [1:0] {
    READ_ACCEPT_ADDRESS,
    READ_WAIT_LATENCY,
    READ_RETURN_DATA
  } read_state_e;

  typedef enum logic [1:0] {
    WRITE_ACCEPT_ADDRESS,
    WRITE_RECEIVE_DATA,
    WRITE_WAIT_LATENCY,
    WRITE_RETURN_RESPONSE
  } write_state_e;

  read_state_e  read_state_q;
  read_state_e  read_state_d;
  write_state_e write_state_q;
  write_state_e write_state_d;

  axi4_read_address_t read_address_q;
  axi4_read_address_t read_address_d;
  logic [MEM_AXI_ADDR_WIDTH-1:0] read_beat_addr_q;
  logic [MEM_AXI_ADDR_WIDTH-1:0] read_beat_addr_d;
  logic [7:0] read_beat_index_q;
  logic [7:0] read_beat_index_d;
  logic [31:0] read_delay_cycle_count_q;
  logic [31:0] read_delay_cycle_count_d;

  logic [MEM_AXI_DATA_WIDTH-1:0] read_response_data_q;
  logic [MEM_AXI_ID_WIDTH-1:0] read_response_id_q;
  logic read_response_last_q;

  axi4_write_address_t write_address_q;
  axi4_write_address_t write_address_d;
  logic [MEM_AXI_ADDR_WIDTH-1:0] write_beat_addr_q;
  logic [MEM_AXI_ADDR_WIDTH-1:0] write_beat_addr_d;
  logic [7:0] write_beat_index_q;
  logic [7:0] write_beat_index_d;
  logic [31:0] write_delay_cycle_count_q;
  logic [31:0] write_delay_cycle_count_d;
  axi4_write_response_t write_response_q;
  axi4_write_response_t write_response_d;

  logic [15:0] read_latency_lfsr_q;
  logic [15:0] write_latency_lfsr_q;
  logic random_latency_enable;
  int unsigned random_latency_seed;

  logic read_address_handshake;
  logic read_data_handshake;
  logic write_address_handshake;
  logic write_data_handshake;
  logic write_response_handshake;

  logic read_response_load_event;
  logic [MEM_AXI_ADDR_WIDTH-1:0] read_response_load_addr;
  logic [MEM_AXI_ID_WIDTH-1:0] read_response_load_id;
  logic read_response_load_last;
  logic [2:0] read_response_load_size;

  logic                        write_data_store_event;
  logic [MEM_AXI_ADDR_WIDTH-1:0]  write_data_store_addr;
  logic [MEM_AXI_DATA_WIDTH-1:0]  write_data_store_data;
  logic [AXI4_STRB_WIDTH-1:0] write_data_store_strobe;

  int unsigned accepted_read_latency;
  int unsigned accepted_write_latency;

  function automatic logic [15:0] next_lfsr_value(input logic [15:0] value);
    return {value[14:0], value[15] ^ value[13] ^ value[12] ^ value[10]};
  endfunction

  function automatic int unsigned select_latency(
      input logic [15:0] lfsr_value,
      input int unsigned fixed_latency
  );
    if (random_latency_enable) begin
      return 1 + (int'($unsigned(lfsr_value)) % RANDOM_LATENCY_MAX);
    end
    return fixed_latency;
  endfunction

  function automatic logic [MEM_AXI_ADDR_WIDTH-1:0] next_burst_addr(
      input logic [MEM_AXI_ADDR_WIDTH-1:0] current_addr,
      input logic [MEM_AXI_ADDR_WIDTH-1:0] start_addr,
      input logic [7:0] burst_length,
      input logic [2:0] transfer_size,
      input axi4_burst_e burst_type
  );
    logic [MEM_AXI_ADDR_WIDTH-1:0] bytes_per_beat;
    logic [MEM_AXI_ADDR_WIDTH-1:0] burst_bytes;
    logic [MEM_AXI_ADDR_WIDTH-1:0] wrap_base_addr;
    logic [MEM_AXI_ADDR_WIDTH-1:0] incremented_addr;

    bytes_per_beat = MEM_AXI_ADDR_WIDTH'(1) << transfer_size;
    burst_bytes = bytes_per_beat * MEM_AXI_ADDR_WIDTH'(burst_length + 1'b1);
    incremented_addr = current_addr + bytes_per_beat;
    wrap_base_addr = start_addr & ~(burst_bytes - MEM_AXI_ADDR_WIDTH'(1));

    unique case (burst_type)
      AXI4_BURST_FIXED: return current_addr;
      AXI4_BURST_WRAP: begin
        if (incremented_addr >= wrap_base_addr + burst_bytes) return wrap_base_addr;
        return incremented_addr;
      end
      default: return incremented_addr;
    endcase
  endfunction

  initial begin
    random_latency_enable = $test$plusargs("axi_random_latency");
    if (!$value$plusargs("axi_lfsr_seed=%d", random_latency_seed)) begin
      random_latency_seed = 32'h1;
    end
  end

  assign read_address_handshake = mem_axi_i.ar_valid && mem_axi_o.ar_ready;
  assign read_data_handshake = mem_axi_o.r_valid && mem_axi_i.r_ready;
  assign write_address_handshake = mem_axi_i.aw_valid && mem_axi_o.aw_ready;
  assign write_data_handshake = mem_axi_i.w_valid && mem_axi_o.w_ready;
  assign write_response_handshake = mem_axi_o.b_valid && mem_axi_i.b_ready;

  always_comb begin
    accepted_read_latency = select_latency(
        read_latency_lfsr_q,
        ((read_state_q == READ_ACCEPT_ADDRESS ? mem_axi_i.ar.id : read_address_q.id) ==
         INSTRUCTION_READ_ID) ? IFU_READ_LATENCY : LSU_READ_LATENCY
    );
    accepted_write_latency = select_latency(write_latency_lfsr_q, LSU_WRITE_LATENCY);
  end

  // 第一段：五个AXI4 channel的输出。读写方向可同时推进，各自只维护一个在途事务。
  always_comb begin
    mem_axi_o = '0;

    unique case (read_state_q)
      READ_ACCEPT_ADDRESS: begin
        mem_axi_o.ar_ready = !random_latency_enable || read_latency_lfsr_q[0];
      end
      READ_RETURN_DATA: begin
        mem_axi_o.r.data  = read_response_data_q;
        mem_axi_o.r.id    = read_response_id_q;
        mem_axi_o.r.resp  = AXI4_RESP_OKAY;
        mem_axi_o.r.last  = read_response_last_q;
        mem_axi_o.r_valid = 1'b1;
      end
      default: ;
    endcase

    unique case (write_state_q)
      WRITE_ACCEPT_ADDRESS: begin
        mem_axi_o.aw_ready = !random_latency_enable || write_latency_lfsr_q[0];
        // AW被当前拍接受时，首个W beat可同拍直通，不额外损失一个周期。
        mem_axi_o.w_ready = mem_axi_i.aw_valid && mem_axi_o.aw_ready;
      end
      WRITE_RECEIVE_DATA: begin
        mem_axi_o.w_ready = 1'b1;
      end
      WRITE_RETURN_RESPONSE: begin
        mem_axi_o.b       = write_response_q;
        mem_axi_o.b_valid = 1'b1;
      end
      default: ;
    endcase
  end

  // 第二段：读事务状态和每个beat的地址进度。
  always_comb begin
    read_state_d             = read_state_q;
    read_address_d           = read_address_q;
    read_beat_addr_d         = read_beat_addr_q;
    read_beat_index_d        = read_beat_index_q;
    read_delay_cycle_count_d = read_delay_cycle_count_q;

    read_response_load_event          = 1'b0;
    read_response_load_addr           = '0;
    read_response_load_id             = '0;
    read_response_load_last           = 1'b0;
    read_response_load_size           = '0;

    unique case (read_state_q)
      READ_ACCEPT_ADDRESS: begin
        if (read_address_handshake) begin
          read_address_d   = mem_axi_i.ar;
          read_beat_addr_d = mem_axi_i.ar.addr;
          read_beat_index_d = '0;

          read_response_load_event          = 1'b1;
          read_response_load_addr           = mem_axi_i.ar.addr;
          read_response_load_id             = mem_axi_i.ar.id;
          read_response_load_last           = mem_axi_i.ar.len == 8'd0;
          read_response_load_size           = mem_axi_i.ar.size;

          if (accepted_read_latency == 1) begin
            read_state_d = READ_RETURN_DATA;
          end else begin
            read_delay_cycle_count_d = accepted_read_latency - 1;
            read_state_d             = READ_WAIT_LATENCY;
          end
        end
      end

      READ_WAIT_LATENCY: begin
        if (read_delay_cycle_count_q == 1) begin
          read_delay_cycle_count_d = '0;
          read_state_d             = READ_RETURN_DATA;
        end else begin
          read_delay_cycle_count_d = read_delay_cycle_count_q - 1;
        end
      end

      READ_RETURN_DATA: begin
        if (read_data_handshake) begin
          if (read_response_last_q) begin
            read_state_d = READ_ACCEPT_ADDRESS;
          end else begin
            read_beat_addr_d = next_burst_addr(
                read_beat_addr_q,
                read_address_q.addr,
                read_address_q.len,
                read_address_q.size,
                read_address_q.burst
            );
            read_beat_index_d = read_beat_index_q + 1'b1;

            read_response_load_event          = 1'b1;
            read_response_load_addr           = read_beat_addr_d;
            read_response_load_id             = read_address_q.id;
            read_response_load_last           = read_beat_index_d == read_address_q.len;
            read_response_load_size           = read_address_q.size;

            if (accepted_read_latency == 1) begin
              read_state_d = READ_RETURN_DATA;
            end else begin
              read_delay_cycle_count_d = accepted_read_latency - 1;
              read_state_d             = READ_WAIT_LATENCY;
            end
          end
        end
      end

      default: read_state_d = READ_ACCEPT_ADDRESS;
    endcase
  end

  // 第二段：写事务状态。AW确定事务属性，随后每个W beat直接写入DPI存储器。
  always_comb begin
    write_state_d             = write_state_q;
    write_address_d           = write_address_q;
    write_beat_addr_d         = write_beat_addr_q;
    write_beat_index_d        = write_beat_index_q;
    write_delay_cycle_count_d = write_delay_cycle_count_q;
    write_response_d          = write_response_q;

    write_data_store_event  = 1'b0;
    write_data_store_addr   = '0;
    write_data_store_data   = '0;
    write_data_store_strobe = '0;

    unique case (write_state_q)
      WRITE_ACCEPT_ADDRESS: begin
        if (write_address_handshake) begin
          write_address_d    = mem_axi_i.aw;
          write_beat_addr_d  = mem_axi_i.aw.addr;
          write_beat_index_d = '0;
          write_response_d.id   = mem_axi_i.aw.id;
          write_response_d.resp = AXI4_RESP_OKAY;

          if (write_data_handshake) begin
            write_data_store_event  = 1'b1;
            write_data_store_addr   = mem_axi_i.aw.addr;
            write_data_store_data   = mem_axi_i.w.data;
            write_data_store_strobe = mem_axi_i.w.strb;
            if (mem_axi_i.w.last) begin
              if (accepted_write_latency == 1) begin
                write_state_d = WRITE_RETURN_RESPONSE;
              end else begin
                write_delay_cycle_count_d = accepted_write_latency - 1;
                write_state_d             = WRITE_WAIT_LATENCY;
              end
            end else begin
              write_beat_addr_d = next_burst_addr(
                  mem_axi_i.aw.addr,
                  mem_axi_i.aw.addr,
                  mem_axi_i.aw.len,
                  mem_axi_i.aw.size,
                  mem_axi_i.aw.burst
              );
              write_beat_index_d = 8'd1;
              write_state_d      = WRITE_RECEIVE_DATA;
            end
          end else begin
            write_state_d = WRITE_RECEIVE_DATA;
          end
        end
      end

      WRITE_RECEIVE_DATA: begin
        if (write_data_handshake) begin
          write_data_store_event  = 1'b1;
          write_data_store_addr   = write_beat_addr_q;
          write_data_store_data   = mem_axi_i.w.data;
          write_data_store_strobe = mem_axi_i.w.strb;

          if (mem_axi_i.w.last) begin
            if (accepted_write_latency == 1) begin
              write_state_d = WRITE_RETURN_RESPONSE;
            end else begin
              write_delay_cycle_count_d = accepted_write_latency - 1;
              write_state_d             = WRITE_WAIT_LATENCY;
            end
          end else begin
            write_beat_addr_d = next_burst_addr(
                write_beat_addr_q,
                write_address_q.addr,
                write_address_q.len,
                write_address_q.size,
                write_address_q.burst
            );
            write_beat_index_d = write_beat_index_q + 1'b1;
          end
        end
      end

      WRITE_WAIT_LATENCY: begin
        if (write_delay_cycle_count_q == 1) begin
          write_delay_cycle_count_d = '0;
          write_state_d             = WRITE_RETURN_RESPONSE;
        end else begin
          write_delay_cycle_count_d = write_delay_cycle_count_q - 1;
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

  // 第三段：读状态、读事务属性和响应数据分别更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_state_q             <= READ_ACCEPT_ADDRESS;
      read_delay_cycle_count_q <= '0;
    end else begin
      read_state_q             <= read_state_d;
      read_delay_cycle_count_q <= read_delay_cycle_count_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_address_q    <= '0;
      read_beat_addr_q  <= '0;
      read_beat_index_q <= '0;
    end else begin
      read_address_q    <= read_address_d;
      read_beat_addr_q  <= read_beat_addr_d;
      read_beat_index_q <= read_beat_index_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_response_data_q <= '0;
      read_response_id_q   <= '0;
      read_response_last_q <= 1'b0;
    end else if (read_response_load_event) begin
      read_response_data_q <= axi4_data_t'(pmem_read_data(
          int'(read_response_load_addr),
          1 << read_response_load_size,
          MEM_AXI_DATA_BYTE_COUNT
      ));
      read_response_id_q   <= read_response_load_id;
      read_response_last_q <= read_response_load_last;
    end
  end

  // 第三段：写状态、写事务属性和写响应分别更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_state_q             <= WRITE_ACCEPT_ADDRESS;
      write_delay_cycle_count_q <= '0;
    end else begin
      write_state_q             <= write_state_d;
      write_delay_cycle_count_q <= write_delay_cycle_count_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_address_q    <= '0;
      write_beat_addr_q  <= '0;
      write_beat_index_q <= '0;
      write_response_q   <= '0;
    end else begin
      write_address_q    <= write_address_d;
      write_beat_addr_q  <= write_beat_addr_d;
      write_beat_index_q <= write_beat_index_d;
      write_response_q   <= write_response_d;
    end
  end

  always_ff @(posedge clk_i) begin
    if (write_data_store_event) begin
      pmem_write(
          int'(write_data_store_addr),
          longint'(write_data_store_data),
          byte'(write_data_store_strobe),
          MEM_AXI_DATA_BYTE_COUNT
      );
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_latency_lfsr_q  <= random_latency_seed[15:0] | 16'h1;
      write_latency_lfsr_q <= (random_latency_seed[15:0] ^ 16'hb400) | 16'h1;
    end else if (random_latency_enable) begin
      read_latency_lfsr_q  <= next_lfsr_value(read_latency_lfsr_q);
      write_latency_lfsr_q <= next_lfsr_value(write_latency_lfsr_q);
    end
  end

endmodule
