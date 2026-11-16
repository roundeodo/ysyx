// Processor memory AXI to ysyxSoC AXI32 width converter.
//
// RV32配置中两侧同宽，五个channel保持组合直通。RV64配置中，窄访问保留原事务，
// 只转换64位data lane；单拍64位访问在普通存储区转换成两个32位beat。MMIO不允许
// 拆分，转换器在任何下游请求发出前返回DECERR，避免设备只看到半次访问。
module riscv32_axi4_soc_width_converter
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
  import riscv32_ysyx_soc_axi4_pkg::*;
  import riscv32_addr_map_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    input  axi4_manager_to_target_t upstream_manager_i,
    output axi4_target_to_manager_t upstream_manager_o,

    output ysyx_soc_axi4_manager_to_target_t downstream_manager_o,
    input  ysyx_soc_axi4_target_to_manager_t downstream_manager_i
);

  pma_attr_t read_address_memory_attr;
  pma_attr_t write_address_memory_attr;

  riscv32_pma u_read_address_pma (
      .lookup_addr_i (phys_addr_t'(upstream_manager_i.ar.addr)),
      .memory_attr_o (read_address_memory_attr)
  );

  riscv32_pma u_write_address_pma (
      .lookup_addr_i (phys_addr_t'(upstream_manager_i.aw.addr)),
      .memory_attr_o (write_address_memory_attr)
  );

  function automatic axi4_resp_e merge_response(
      input  axi4_resp_e first_response,
      input  axi4_resp_e second_response
  );
    if ((first_response == AXI4_RESP_DECERR) ||
        (second_response == AXI4_RESP_DECERR)) begin
      return AXI4_RESP_DECERR;
    end
    if ((first_response == AXI4_RESP_SLVERR) ||
        (second_response == AXI4_RESP_SLVERR)) begin
      return AXI4_RESP_SLVERR;
    end
    if ((first_response == AXI4_RESP_EXOKAY) ||
        (second_response == AXI4_RESP_EXOKAY)) begin
      return AXI4_RESP_EXOKAY;
    end
    return AXI4_RESP_OKAY;
  endfunction

  function automatic axi4_addr_t next_burst_addr(
      input  axi4_addr_t  current_addr,
      input  axi4_addr_t  start_addr,
      input  logic [7:0]  burst_length,
      input  logic [2:0]  transfer_size,
      input  axi4_burst_e burst_type
  );
    axi4_addr_t bytes_per_beat;
    axi4_addr_t burst_bytes;
    axi4_addr_t wrap_base_addr;
    axi4_addr_t incremented_addr;

    bytes_per_beat   = axi4_addr_t'(1) << transfer_size;
    burst_bytes      = bytes_per_beat * (axi4_addr_t'(burst_length) + axi4_addr_t'(1));
    incremented_addr = current_addr + bytes_per_beat;
    wrap_base_addr   = start_addr & ~(burst_bytes - axi4_addr_t'(1));

    unique case (burst_type)
      AXI4_BURST_FIXED: return current_addr;
      AXI4_BURST_WRAP: begin
        if (incremented_addr >= wrap_base_addr + burst_bytes)
          return wrap_base_addr;
        return incremented_addr;
      end
      default: return incremented_addr;
    endcase
  endfunction

  generate
    if (MEM_AXI_DATA_WIDTH == YSYX_SOC_AXI_DATA_WIDTH) begin : g_same_width
      // 同宽配置不引入状态、缓冲或额外周期。这里只做不同package类型之间的逐字段映射。
      always_comb begin
        downstream_manager_o = '0;
        upstream_manager_o   = '0;

        downstream_manager_o.aw.addr  = upstream_manager_i.aw.addr;
        downstream_manager_o.aw.id    = upstream_manager_i.aw.id;
        downstream_manager_o.aw.len   = upstream_manager_i.aw.len;
        downstream_manager_o.aw.size  = upstream_manager_i.aw.size;
        downstream_manager_o.aw.burst = upstream_manager_i.aw.burst;
        downstream_manager_o.aw_valid = upstream_manager_i.aw_valid;

        downstream_manager_o.w.data  = upstream_manager_i.w.data;
        downstream_manager_o.w.strb  = upstream_manager_i.w.strb;
        downstream_manager_o.w.last  = upstream_manager_i.w.last;
        downstream_manager_o.w_valid = upstream_manager_i.w_valid;
        downstream_manager_o.b_ready = upstream_manager_i.b_ready;

        downstream_manager_o.ar.addr  = upstream_manager_i.ar.addr;
        downstream_manager_o.ar.id    = upstream_manager_i.ar.id;
        downstream_manager_o.ar.len   = upstream_manager_i.ar.len;
        downstream_manager_o.ar.size  = upstream_manager_i.ar.size;
        downstream_manager_o.ar.burst = upstream_manager_i.ar.burst;
        downstream_manager_o.ar_valid = upstream_manager_i.ar_valid;
        downstream_manager_o.r_ready  = upstream_manager_i.r_ready;

        upstream_manager_o.aw_ready = downstream_manager_i.aw_ready;
        upstream_manager_o.w_ready  = downstream_manager_i.w_ready;
        upstream_manager_o.b.id     = downstream_manager_i.b.id;
        upstream_manager_o.b.resp   = downstream_manager_i.b.resp;
        upstream_manager_o.b_valid  = downstream_manager_i.b_valid;

        upstream_manager_o.ar_ready = downstream_manager_i.ar_ready;
        upstream_manager_o.r.data   = downstream_manager_i.r.data;
        upstream_manager_o.r.id     = downstream_manager_i.r.id;
        upstream_manager_o.r.resp   = downstream_manager_i.r.resp;
        upstream_manager_o.r.last   = downstream_manager_i.r.last;
        upstream_manager_o.r_valid  = downstream_manager_i.r_valid;
      end
    end else begin : g_width_conversion
      localparam int unsigned DOWNSTREAM_MAX_TRANSFER_SIZE =
          $clog2(YSYX_SOC_AXI_DATA_BYTE_COUNT);

      typedef enum logic [1:0] {
        READ_ACCEPT_ADDRESS,
        READ_FORWARD_NARROW_RESPONSE,
        READ_RECEIVE_WIDE_RESPONSE,
        READ_RETURN_LOCAL_ERROR
      } read_state_e;

      typedef enum logic [1:0] {
        WRITE_COLLECT_ADDRESS_DATA,
        WRITE_FORWARD_TRANSACTION,
        WRITE_WAIT_RESPONSE,
        WRITE_RETURN_LOCAL_ERROR
      } write_state_e;

      read_state_e  read_state_q;
      read_state_e  read_state_d;
      write_state_e write_state_q;
      write_state_e write_state_d;

      axi4_read_address_t  read_address_q;
      axi4_read_address_t  read_address_d;
      axi4_addr_t          current_read_beat_addr_q;
      axi4_addr_t          current_read_beat_addr_d;
      ysyx_soc_axi4_data_t wide_read_low_data_q;
      ysyx_soc_axi4_data_t wide_read_low_data_d;
      axi4_resp_e          wide_read_first_response_q;
      axi4_resp_e          wide_read_first_response_d;
      logic                wide_read_second_beat_q;
      logic                wide_read_second_beat_d;

      axi4_write_address_t write_address_q;
      axi4_write_address_t write_address_d;
      logic                write_address_present_q;
      logic                write_address_present_d;
      axi4_write_data_t    write_data_q;
      axi4_write_data_t    write_data_d;
      logic                write_data_present_q;
      logic                write_data_present_d;
      axi4_addr_t          current_write_beat_addr_q;
      axi4_addr_t          current_write_beat_addr_d;
      logic                write_width_conversion_q;
      logic                write_width_conversion_d;
      logic                downstream_write_address_pending_q;
      logic                downstream_write_address_pending_d;
      logic                wide_write_upper_half_q;
      logic                wide_write_upper_half_d;
      logic                write_last_data_forwarded_q;
      logic                write_last_data_forwarded_d;

      logic upstream_read_address_handshake;
      logic downstream_read_data_handshake;
      logic upstream_write_address_handshake;
      logic upstream_write_data_handshake;
      logic downstream_write_address_handshake;
      logic downstream_write_data_handshake;
      logic downstream_write_response_handshake;
      logic upstream_write_response_handshake;

      logic read_width_conversion_requested;
      logic read_request_supported;
      logic write_width_conversion_requested;
      logic write_request_supported;
      logic current_write_data_completed;

      axi4_target_to_manager_t          read_upstream_response;
      axi4_target_to_manager_t          write_upstream_response;
      ysyx_soc_axi4_manager_to_target_t read_downstream_request;
      ysyx_soc_axi4_manager_to_target_t write_downstream_request;

      assign read_width_conversion_requested =
          upstream_manager_i.ar.size > 3'(DOWNSTREAM_MAX_TRANSFER_SIZE);
      assign read_request_supported = !read_width_conversion_requested ||
          ((upstream_manager_i.ar.size == 3'd3) &&
           (upstream_manager_i.ar.len == 8'd0) &&
           (upstream_manager_i.ar.addr[2:0] == 3'b000) &&
           read_address_memory_attr.width_conversion_supported);

      assign write_width_conversion_requested =
          upstream_manager_i.aw.size > 3'(DOWNSTREAM_MAX_TRANSFER_SIZE);
      assign write_request_supported = !write_width_conversion_requested ||
          ((upstream_manager_i.aw.size == 3'd3) &&
           (upstream_manager_i.aw.len == 8'd0) &&
           (upstream_manager_i.aw.addr[2:0] == 3'b000) &&
           write_address_memory_attr.width_conversion_supported);

      assign upstream_read_address_handshake =
          upstream_manager_i.ar_valid && upstream_manager_o.ar_ready;
      assign downstream_read_data_handshake =
          downstream_manager_i.r_valid && downstream_manager_o.r_ready;
      assign upstream_write_address_handshake =
          upstream_manager_i.aw_valid && upstream_manager_o.aw_ready;
      assign upstream_write_data_handshake =
          upstream_manager_i.w_valid && upstream_manager_o.w_ready;
      assign downstream_write_address_handshake =
          downstream_manager_o.aw_valid && downstream_manager_i.aw_ready;
      assign downstream_write_data_handshake =
          downstream_manager_o.w_valid && downstream_manager_i.w_ready;
      assign downstream_write_response_handshake =
          downstream_manager_i.b_valid && downstream_manager_o.b_ready;
      assign upstream_write_response_handshake =
          upstream_manager_o.b_valid && upstream_manager_i.b_ready;

      assign current_write_data_completed = downstream_write_data_handshake &&
          (!write_width_conversion_q || wide_write_upper_half_q);

      // 读通道输出：AR 组合直通，握手后保存事务身份和 beat 地址，保持到 RLAST。
      always_comb begin
        read_upstream_response  = '0;
        read_downstream_request = '0;

        unique case (read_state_q)
          READ_ACCEPT_ADDRESS: begin
            if (upstream_manager_i.ar_valid) begin
              if (read_request_supported) begin
                read_downstream_request.ar.addr = upstream_manager_i.ar.addr;
                read_downstream_request.ar.id   = upstream_manager_i.ar.id;
                read_downstream_request.ar.len  = read_width_conversion_requested
                    ? 8'd1 : upstream_manager_i.ar.len;
                read_downstream_request.ar.size = read_width_conversion_requested
                    ? 3'(DOWNSTREAM_MAX_TRANSFER_SIZE) : upstream_manager_i.ar.size;
                read_downstream_request.ar.burst = upstream_manager_i.ar.burst;
                read_downstream_request.ar_valid = 1'b1;
                read_upstream_response.ar_ready  = downstream_manager_i.ar_ready;
              end else begin
                // 本地错误响应也通过AR握手取得事务ID，但绝不向下游发出AR。
                read_upstream_response.ar_ready = 1'b1;
              end
            end
          end

          READ_FORWARD_NARROW_RESPONSE: begin
            read_upstream_response.r.data = '0;
            if (current_read_beat_addr_q[2]) begin
              read_upstream_response.r.data[63:32] = downstream_manager_i.r.data;
            end else begin
              read_upstream_response.r.data[31:0] = downstream_manager_i.r.data;
            end
            read_upstream_response.r.id     = downstream_manager_i.r.id;
            read_upstream_response.r.resp   = downstream_manager_i.r.resp;
            read_upstream_response.r.last   = downstream_manager_i.r.last;
            read_upstream_response.r_valid  = downstream_manager_i.r_valid;
            read_downstream_request.r_ready = upstream_manager_i.r_ready;
          end

          READ_RECEIVE_WIDE_RESPONSE: begin
            if (!wide_read_second_beat_q) begin
              // 第一拍只写入内部低32位缓冲，不提前向上游宣告完整64位数据有效。
              read_downstream_request.r_ready = 1'b1;
            end else begin
              read_upstream_response.r.data = {
                downstream_manager_i.r.data,
                wide_read_low_data_q
              };
              read_upstream_response.r.id   = read_address_q.id;
              read_upstream_response.r.resp = merge_response(
                  wide_read_first_response_q,
                  downstream_manager_i.r.resp
              );
              read_upstream_response.r.last   = 1'b1;
              read_upstream_response.r_valid  = downstream_manager_i.r_valid;
              read_downstream_request.r_ready = upstream_manager_i.r_ready;
            end
          end

          READ_RETURN_LOCAL_ERROR: begin
            read_upstream_response.r.data  = '0;
            read_upstream_response.r.id    = read_address_q.id;
            read_upstream_response.r.resp  = AXI4_RESP_DECERR;
            read_upstream_response.r.last  = 1'b1;
            read_upstream_response.r_valid = 1'b1;
          end

          default: ;
        endcase
      end

      // 写通道输出：AW 和 W 分别进入单项缓冲，切断处理器到 SoC 引脚的组合路径。
      always_comb begin
        write_upstream_response  = '0;
        write_downstream_request = '0;

        unique case (write_state_q)
          WRITE_COLLECT_ADDRESS_DATA: begin
            write_upstream_response.aw_ready = !write_address_present_q;
            write_upstream_response.w_ready  = !write_data_present_q;
          end

          WRITE_FORWARD_TRANSACTION: begin
            write_downstream_request.aw.addr = write_address_q.addr;
            write_downstream_request.aw.id   = write_address_q.id;
            write_downstream_request.aw.len  = write_width_conversion_q
                ? 8'd1 : write_address_q.len;
            write_downstream_request.aw.size = write_width_conversion_q
                ? 3'(DOWNSTREAM_MAX_TRANSFER_SIZE) : write_address_q.size;
            write_downstream_request.aw.burst = write_address_q.burst;
            write_downstream_request.aw_valid = downstream_write_address_pending_q;

            write_upstream_response.w_ready = !write_data_present_q;
            if (write_data_present_q) begin
              if (write_width_conversion_q) begin
                write_downstream_request.w.data = wide_write_upper_half_q
                    ? write_data_q.data[63:32] : write_data_q.data[31:0];
                write_downstream_request.w.strb = wide_write_upper_half_q
                    ? write_data_q.strb[7:4] : write_data_q.strb[3:0];
                write_downstream_request.w.last = wide_write_upper_half_q && write_data_q.last;
              end else begin
                write_downstream_request.w.data = current_write_beat_addr_q[2]
                    ? write_data_q.data[63:32] : write_data_q.data[31:0];
                write_downstream_request.w.strb = current_write_beat_addr_q[2]
                    ? write_data_q.strb[7:4] : write_data_q.strb[3:0];
                write_downstream_request.w.last = write_data_q.last;
              end
              write_downstream_request.w_valid = 1'b1;
            end
          end

          WRITE_WAIT_RESPONSE: begin
            write_upstream_response.b.id     = downstream_manager_i.b.id;
            write_upstream_response.b.resp   = downstream_manager_i.b.resp;
            write_upstream_response.b_valid  = downstream_manager_i.b_valid;
            write_downstream_request.b_ready = upstream_manager_i.b_ready;
          end

          WRITE_RETURN_LOCAL_ERROR: begin
            // 在本地错误路径中先接收并丢弃到WLAST，随后才返回一次B响应。
            if (write_data_present_q) begin
              write_upstream_response.w_ready = 1'b0;
            end else begin
              write_upstream_response.w_ready = 1'b1;
            end
            if (write_last_data_forwarded_q) begin
              write_upstream_response.w_ready = 1'b0;
              write_upstream_response.b.id    = write_address_q.id;
              write_upstream_response.b.resp  = AXI4_RESP_DECERR;
              write_upstream_response.b_valid = 1'b1;
            end
          end

          default: ;
        endcase
      end

      // 五个channel只在这里合并到模块端口，保证每个聚合输出只有一个组合驱动源。
      always_comb begin
        upstream_manager_o          = read_upstream_response;
        upstream_manager_o.aw_ready = write_upstream_response.aw_ready;
        upstream_manager_o.w_ready  = write_upstream_response.w_ready;
        upstream_manager_o.b        = write_upstream_response.b;
        upstream_manager_o.b_valid  = write_upstream_response.b_valid;

        downstream_manager_o          = read_downstream_request;
        downstream_manager_o.aw       = write_downstream_request.aw;
        downstream_manager_o.aw_valid = write_downstream_request.aw_valid;
        downstream_manager_o.w        = write_downstream_request.w;
        downstream_manager_o.w_valid  = write_downstream_request.w_valid;
        downstream_manager_o.b_ready  = write_downstream_request.b_ready;
      end

      // 读通道下一状态：跟踪当前 beat；宽读先保存低半，再合并高半返回。
      always_comb begin
        read_state_d               = read_state_q;
        read_address_d             = read_address_q;
        current_read_beat_addr_d   = current_read_beat_addr_q;
        wide_read_low_data_d       = wide_read_low_data_q;
        wide_read_first_response_d = wide_read_first_response_q;
        wide_read_second_beat_d    = wide_read_second_beat_q;

        unique case (read_state_q)
          READ_ACCEPT_ADDRESS: begin
            if (upstream_read_address_handshake) begin
              read_address_d           = upstream_manager_i.ar;
              current_read_beat_addr_d = upstream_manager_i.ar.addr;
              wide_read_second_beat_d  = 1'b0;
              if (!read_request_supported) begin
                read_state_d = READ_RETURN_LOCAL_ERROR;
              end else if (read_width_conversion_requested) begin
                read_state_d = READ_RECEIVE_WIDE_RESPONSE;
              end else begin
                read_state_d = READ_FORWARD_NARROW_RESPONSE;
              end
            end
          end

          READ_FORWARD_NARROW_RESPONSE: begin
            if (downstream_read_data_handshake) begin
              if (downstream_manager_i.r.last) begin
                read_address_d           = '0;
                current_read_beat_addr_d = '0;
                read_state_d             = READ_ACCEPT_ADDRESS;
              end else begin
                current_read_beat_addr_d = next_burst_addr(
                    current_read_beat_addr_q,
                    read_address_q.addr,
                    read_address_q.len,
                    read_address_q.size,
                    read_address_q.burst
                );
              end
            end
          end

          READ_RECEIVE_WIDE_RESPONSE: begin
            if (downstream_read_data_handshake) begin
              if (!wide_read_second_beat_q) begin
                wide_read_low_data_d       = downstream_manager_i.r.data;
                wide_read_first_response_d = downstream_manager_i.r.resp;
                wide_read_second_beat_d    = 1'b1;
              end else begin
                read_address_d             = '0;
                wide_read_low_data_d       = '0;
                wide_read_first_response_d = AXI4_RESP_OKAY;
                wide_read_second_beat_d    = 1'b0;
                read_state_d               = READ_ACCEPT_ADDRESS;
              end
            end
          end

          READ_RETURN_LOCAL_ERROR: begin
            if (read_upstream_response.r_valid && upstream_manager_i.r_ready) begin
              read_address_d = '0;
              read_state_d   = READ_ACCEPT_ADDRESS;
            end
          end

          default: begin
            read_state_d = READ_ACCEPT_ADDRESS;
          end
        endcase
      end

      // 写通道下一状态：独立接收 AW/W，推进拆分 beat，最后等待响应。
      always_comb begin
        write_state_d                      = write_state_q;
        write_address_d                    = write_address_q;
        write_address_present_d            = write_address_present_q;
        write_data_d                       = write_data_q;
        write_data_present_d               = write_data_present_q;
        current_write_beat_addr_d          = current_write_beat_addr_q;
        write_width_conversion_d           = write_width_conversion_q;
        downstream_write_address_pending_d = downstream_write_address_pending_q;
        wide_write_upper_half_d            = wide_write_upper_half_q;
        write_last_data_forwarded_d        = write_last_data_forwarded_q;

        unique case (write_state_q)
          WRITE_COLLECT_ADDRESS_DATA: begin
            if (upstream_write_data_handshake) begin
              write_data_d         = upstream_manager_i.w;
              write_data_present_d = 1'b1;
            end

            if (upstream_write_address_handshake) begin
              write_address_d             = upstream_manager_i.aw;
              write_address_present_d     = 1'b1;
              current_write_beat_addr_d   = upstream_manager_i.aw.addr;
              write_width_conversion_d    = write_width_conversion_requested;
              wide_write_upper_half_d     = 1'b0;
              write_last_data_forwarded_d = 1'b0;

              if (write_request_supported) begin
                downstream_write_address_pending_d = 1'b1;
                write_state_d                      = WRITE_FORWARD_TRANSACTION;
              end else begin
                downstream_write_address_pending_d = 1'b0;
                write_state_d                      = WRITE_RETURN_LOCAL_ERROR;
              end
            end
          end

          WRITE_FORWARD_TRANSACTION: begin
            if (upstream_write_data_handshake) begin
              write_data_d         = upstream_manager_i.w;
              write_data_present_d = 1'b1;
            end

            if (downstream_write_address_handshake) begin
              downstream_write_address_pending_d = 1'b0;
            end

            if (downstream_write_data_handshake) begin
              if (write_width_conversion_q && !wide_write_upper_half_q) begin
                wide_write_upper_half_d = 1'b1;
              end else begin
                wide_write_upper_half_d = 1'b0;
                write_data_present_d    = 1'b0;
                if (write_data_q.last) begin
                  write_last_data_forwarded_d = 1'b1;
                end else begin
                  current_write_beat_addr_d = next_burst_addr(
                      current_write_beat_addr_q,
                      write_address_q.addr,
                      write_address_q.len,
                      write_address_q.size,
                      write_address_q.burst
                  );
                end
              end
            end

            if ((!downstream_write_address_pending_q ||
                 downstream_write_address_handshake) &&
                (write_last_data_forwarded_q ||
                 (current_write_data_completed && write_data_q.last))) begin
              write_state_d = WRITE_WAIT_RESPONSE;
            end
          end

          WRITE_WAIT_RESPONSE: begin
            if (downstream_write_response_handshake) begin
              write_address_d                    = '0;
              write_address_present_d            = 1'b0;
              write_data_d                       = '0;
              write_data_present_d               = 1'b0;
              current_write_beat_addr_d          = '0;
              write_width_conversion_d           = 1'b0;
              downstream_write_address_pending_d = 1'b0;
              wide_write_upper_half_d            = 1'b0;
              write_last_data_forwarded_d        = 1'b0;
              write_state_d                      = WRITE_COLLECT_ADDRESS_DATA;
            end
          end

          WRITE_RETURN_LOCAL_ERROR: begin
            if (write_data_present_q && !write_last_data_forwarded_q) begin
              write_last_data_forwarded_d = write_data_q.last;
              write_data_present_d        = 1'b0;
            end else if (upstream_write_data_handshake) begin
              write_last_data_forwarded_d = upstream_manager_i.w.last;
            end

            if (upstream_write_response_handshake) begin
              write_address_d             = '0;
              write_address_present_d     = 1'b0;
              write_data_d                = '0;
              write_data_present_d        = 1'b0;
              write_last_data_forwarded_d = 1'b0;
              write_state_d               = WRITE_COLLECT_ADDRESS_DATA;
            end
          end

          default: write_state_d = WRITE_COLLECT_ADDRESS_DATA;
        endcase
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          read_state_q               <= READ_ACCEPT_ADDRESS;
          read_address_q             <= '0;
          current_read_beat_addr_q   <= '0;
          wide_read_low_data_q       <= '0;
          wide_read_first_response_q <= AXI4_RESP_OKAY;
          wide_read_second_beat_q    <= 1'b0;
        end else begin
          read_state_q               <= read_state_d;
          read_address_q             <= read_address_d;
          current_read_beat_addr_q   <= current_read_beat_addr_d;
          wide_read_low_data_q       <= wide_read_low_data_d;
          wide_read_first_response_q <= wide_read_first_response_d;
          wide_read_second_beat_q    <= wide_read_second_beat_d;
        end
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          write_state_q                      <= WRITE_COLLECT_ADDRESS_DATA;
          write_address_q                    <= '0;
          write_address_present_q            <= 1'b0;
          write_data_q                       <= '0;
          write_data_present_q               <= 1'b0;
          current_write_beat_addr_q          <= '0;
          write_width_conversion_q           <= 1'b0;
          downstream_write_address_pending_q <= 1'b0;
          wide_write_upper_half_q            <= 1'b0;
          write_last_data_forwarded_q        <= 1'b0;
        end else begin
          write_state_q                      <= write_state_d;
          write_address_q                    <= write_address_d;
          write_address_present_q            <= write_address_present_d;
          write_data_q                       <= write_data_d;
          write_data_present_q               <= write_data_present_d;
          current_write_beat_addr_q          <= current_write_beat_addr_d;
          write_width_conversion_q           <= write_width_conversion_d;
          downstream_write_address_pending_q <= downstream_write_address_pending_d;
          wide_write_upper_half_q            <= wide_write_upper_half_d;
          write_last_data_forwarded_q        <= write_last_data_forwarded_d;
        end
      end

`ifndef SYNTHESIS
      initial begin
        assert (MEM_AXI_DATA_WIDTH == 64)
          else
            $fatal(1, "supported width conversion requires a 64-bit processor AXI");
        assert (YSYX_SOC_AXI_DATA_WIDTH == 32)
          else
            $fatal(1, "ysyxSoC AXI boundary must remain 32-bit");
      end

      property p_no_downstream_read_for_local_error;
        @(posedge clk_i) disable iff (!rst_ni)
          read_state_q == READ_RETURN_LOCAL_ERROR |-> !downstream_manager_o.ar_valid;
      endproperty
      assert property (p_no_downstream_read_for_local_error);

      property p_no_downstream_write_for_local_error;
        @(posedge clk_i) disable iff (!rst_ni)
          write_state_q == WRITE_RETURN_LOCAL_ERROR
          |-> (!downstream_manager_o.aw_valid && !downstream_manager_o.w_valid);
      endproperty
      assert property (p_no_downstream_write_for_local_error);
`endif
    end
  endgenerate

endmodule : riscv32_axi4_soc_width_converter
