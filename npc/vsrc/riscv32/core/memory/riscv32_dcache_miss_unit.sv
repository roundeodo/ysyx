// Blocking D-cache的miss、dirty victim写回、line refill和clean写回控制器。
//
// 单个事务上下文依次控制 victim 采集、写回、refill 和元数据提交。
// 普通 miss 的 B 响应与 refill 并行；clean 必须等写回成功后才清 dirty。
module riscv32_dcache_miss_unit
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    input  dcache_miss_req_t  miss_req_i,
    input  logic              miss_req_valid_i,
    output logic              miss_req_ready_o,
    output data_memory_resp_t miss_resp_o,
    output logic              miss_resp_valid_o,
    input  logic              miss_resp_ready_i,

    // clean请求表示把一个已知present+dirty的way写回，并在成功后只清dirty位。
    input  dcache_set_index_t clean_set_index_i,
    input  dcache_way_index_t clean_way_index_i,
    input  dcache_tag_t       clean_tag_i,
    input  logic              clean_req_valid_i,
    output logic              clean_req_ready_o,
    output logic              clean_done_o,
    output logic              clean_access_fault_o,

    output logic               victim_read_enable_o,
    output dcache_set_index_t  victim_read_set_index_o,
    output dcache_word_index_t victim_read_word_index_o,
    input  core_data_t         victim_read_word_data_array_i[DCACHE_WAY_COUNT],

    output logic               data_write_valid_o,
    output dcache_set_index_t  data_write_set_index_o,
    output dcache_way_index_t  data_write_way_index_o,
    output dcache_word_index_t data_write_word_index_o,
    output core_data_t         data_write_word_data_o,
    output core_byte_strobe_t  data_write_byte_strobe_o,

    output logic              metadata_write_valid_o,
    output dcache_set_index_t metadata_write_set_index_o,
    output dcache_way_index_t metadata_write_way_index_o,
    output dcache_tag_t       metadata_write_tag_o,
    output logic              metadata_write_line_present_o,
    output logic              metadata_write_line_dirty_o,

    output logic              line_install_event_o,
    output dcache_set_index_t installed_set_index_o,
    output dcache_way_index_t installed_way_index_o,
    output logic              transaction_present_o,

    output dcache_refill_req_t  refill_req_o,
    output logic                refill_req_valid_o,
    input  logic                refill_req_ready_i,
    input  dcache_refill_resp_t refill_resp_i,
    input  logic                refill_resp_valid_i,
    output logic                refill_resp_ready_o,

    // 行数据独立于请求 payload，保持到 writeback response 握手。
    output dcache_line_data_t      writeback_line_data_o,
    output dcache_writeback_req_t  writeback_req_o,
    output logic                   writeback_req_valid_o,
    input  logic                   writeback_req_ready_i,
    input  dcache_writeback_resp_t writeback_resp_i,
    input  logic                   writeback_resp_valid_i,
    output logic                   writeback_resp_ready_o
);

  typedef enum logic [3:0] {
    MISS_IDLE,
    MISS_READ_VICTIM_WORD,
    MISS_CAPTURE_VICTIM_WORD,
    MISS_SEND_WRITEBACK,
    MISS_WAIT_WRITEBACK_RESPONSE,
    MISS_SEND_REFILL,
    MISS_RECEIVE_REFILL,
    MISS_INSTALL_LINE,
    MISS_RETURN_RESPONSE,
    MISS_UPDATE_CLEAN_METADATA,
    MISS_COMPLETE_CLEAN
  } miss_state_e;

  miss_state_e        state_q, state_d;
  dcache_miss_req_t   miss_context_q, miss_context_d;
  logic               clean_operation_q, clean_operation_d;
  dcache_set_index_t  active_set_index_q, active_set_index_d;
  dcache_way_index_t  active_way_index_q, active_way_index_d;
  dcache_tag_t        victim_tag_q, victim_tag_d;
  dcache_word_index_t victim_word_index_q, victim_word_index_d;
  dcache_line_data_t  victim_line_data_q, victim_line_data_d;
  core_data_t         requested_word_data_q, requested_word_data_d;
  logic               transaction_access_fault_q, transaction_access_fault_d;
  logic               clean_access_fault_q, clean_access_fault_d;
  // dirty victim的B响应可以与新line的AR/R并行，因此必须独立记录它是否尚未返回。
  logic writeback_response_pending_q, writeback_response_pending_d;

  logic       miss_req_handshake;
  logic       clean_req_handshake;
  logic       refill_req_handshake;
  logic       refill_resp_handshake;
  logic       writeback_req_handshake;
  logic       writeback_resp_handshake;
  logic       transaction_fault_after_bus_handshakes;
  logic       writeback_response_completed_after_handshake;
  logic       victim_last_word;
  phys_addr_t victim_line_base_addr;
  phys_addr_t requested_line_base_addr;
  core_data_t refill_word_after_store_merge;

  function automatic core_data_t merge_store_bytes(
      input  core_data_t        original_word,
      input  core_data_t        store_word,
      input  core_byte_strobe_t byte_strobe
  );
    core_data_t merged_word;
    merged_word = original_word;
    for (int unsigned byte_index = 0; byte_index < CORE_DATA_BYTE_COUNT; byte_index++) begin
      if (byte_strobe[byte_index]) begin
        merged_word[byte_index*8+:8] = store_word[byte_index*8+:8];
      end
    end
    return merged_word;
  endfunction

  assign miss_req_handshake       = miss_req_valid_i && miss_req_ready_o;
  assign clean_req_handshake      = clean_req_valid_i && clean_req_ready_o;
  assign refill_req_handshake     = refill_req_valid_o && refill_req_ready_i;
  assign refill_resp_handshake    = refill_resp_valid_i && refill_resp_ready_o;
  assign writeback_req_handshake  = writeback_req_valid_o && writeback_req_ready_i;
  assign writeback_resp_handshake = writeback_resp_valid_i && writeback_resp_ready_o;
  assign transaction_fault_after_bus_handshakes =
      transaction_access_fault_q ||
      (refill_resp_handshake && refill_resp_i.access_fault) ||
      (writeback_resp_handshake && writeback_resp_i.access_fault);
  assign writeback_response_completed_after_handshake =
      !writeback_response_pending_q || writeback_resp_handshake;
  assign victim_last_word =
      victim_word_index_q == dcache_word_index_t'(DCACHE_WORDS_PER_LINE - 1);
  assign victim_line_base_addr =
      (phys_addr_t'(victim_tag_q) << (DCACHE_LINE_OFFSET_W + DCACHE_SET_INDEX_BITS)) |
      (phys_addr_t'(active_set_index_q) << DCACHE_LINE_OFFSET_W);
  assign requested_line_base_addr = miss_context_q.memory_req.addr &
      ~phys_addr_t'(DCACHE_LINE_BYTES - 1);
  assign refill_word_after_store_merge =
      (miss_context_q.memory_req.cmd == MEM_CMD_STORE) &&
      (refill_resp_i.word_index == miss_context_q.word_index) ?
      merge_store_bytes(refill_resp_i.word_data,
      miss_context_q.memory_req.write_data,
      miss_context_q.memory_req.byte_strobe) :
      refill_resp_i.word_data;

  assign transaction_present_o = state_q != MISS_IDLE;

  // 第一段：外部握手与阵列副作用。元数据只有在完整写回/refill成功后才提交。
  always_comb begin
    miss_req_ready_o     = (state_q == MISS_IDLE) && !clean_req_valid_i;
    clean_req_ready_o    = state_q == MISS_IDLE;
    miss_resp_o          = '0;
    miss_resp_valid_o    = 1'b0;
    clean_done_o         = 1'b0;
    clean_access_fault_o = clean_access_fault_q;

    victim_read_enable_o     = 1'b0;
    victim_read_set_index_o  = active_set_index_q;
    victim_read_word_index_o = victim_word_index_q;

    data_write_valid_o       = 1'b0;
    data_write_set_index_o   = active_set_index_q;
    data_write_way_index_o   = active_way_index_q;
    data_write_word_index_o  = refill_resp_i.word_index;
    data_write_word_data_o   = refill_word_after_store_merge;
    data_write_byte_strobe_o = '1;

    metadata_write_valid_o        = 1'b0;
    metadata_write_set_index_o    = active_set_index_q;
    metadata_write_way_index_o    = active_way_index_q;
    metadata_write_tag_o          = victim_tag_q;
    metadata_write_line_present_o = 1'b0;
    metadata_write_line_dirty_o   = 1'b0;

    line_install_event_o  = 1'b0;
    installed_set_index_o = active_set_index_q;
    installed_way_index_o = active_way_index_q;

    refill_req_o                = '0;
    refill_req_o.line_base_addr = requested_line_base_addr;
    refill_req_o.transaction_id = miss_context_q.memory_req.transaction_id;
    refill_req_valid_o          = 1'b0;
    refill_resp_ready_o         = 1'b0;

    writeback_req_o                = '0;
    writeback_req_o.line_base_addr = victim_line_base_addr;
    writeback_line_data_o          = victim_line_data_q;
    writeback_req_o.transaction_id = clean_operation_q ? '0 :
        miss_context_q.memory_req.transaction_id;
    writeback_req_valid_o = 1'b0;
    // B通道独立于refill状态。只要已发出的writeback尚未返回，就持续准备接收响应。
    writeback_resp_ready_o = writeback_response_pending_q;

    unique case (state_q)
      MISS_READ_VICTIM_WORD: begin
        victim_read_enable_o = 1'b1;
      end

      // data array是同步读口。捕获当前word的同时发起下一个word的读取，使dirty
      // victim采集在首拍启动后达到每拍一个word，避免READ/CAPTURE交替产生固定空拍。
      MISS_CAPTURE_VICTIM_WORD: begin
        if (!victim_last_word) begin
          victim_read_enable_o     = 1'b1;
          victim_read_word_index_o = victim_word_index_q + dcache_word_index_t'(1);
        end
      end

      MISS_SEND_WRITEBACK: begin
        writeback_req_valid_o = 1'b1;
      end

      MISS_SEND_REFILL: begin
        // 请求等待期间可重复写 invalid；在任一 refill beat 到达前完成失效。
        metadata_write_valid_o        = 1'b1;
        metadata_write_line_present_o = 1'b0;
        refill_req_valid_o = 1'b1;
      end

      MISS_RECEIVE_REFILL: begin
        refill_resp_ready_o = 1'b1;
        if (refill_resp_handshake && !refill_resp_i.access_fault) begin
          data_write_valid_o = 1'b1;
        end
      end

      MISS_INSTALL_LINE: begin
        metadata_write_valid_o        = 1'b1;
        metadata_write_tag_o          = miss_context_q.requested_tag;
        metadata_write_line_present_o = 1'b1;
        metadata_write_line_dirty_o   = miss_context_q.memory_req.cmd == MEM_CMD_STORE;
        line_install_event_o          = 1'b1;
        miss_resp_o.read_data          = requested_word_data_q;
        miss_resp_o.transaction_id     = miss_context_q.memory_req.transaction_id;
        miss_resp_valid_o              = 1'b1;
      end

      MISS_RETURN_RESPONSE: begin
        miss_resp_o.read_data      = requested_word_data_q;
        miss_resp_o.access_fault   = transaction_access_fault_q;
        miss_resp_o.transaction_id = miss_context_q.memory_req.transaction_id;
        miss_resp_valid_o          = 1'b1;
      end

      MISS_UPDATE_CLEAN_METADATA: begin
        metadata_write_valid_o        = 1'b1;
        metadata_write_tag_o          = victim_tag_q;
        metadata_write_line_present_o = 1'b1;
        metadata_write_line_dirty_o   = 1'b0;
        clean_done_o                  = 1'b1;
      end

      MISS_COMPLETE_CLEAN: begin
        clean_done_o = 1'b1;
      end

      default: ;
    endcase
  end

  // 第二段：状态转换和紧凑事务上下文。
  always_comb begin
    state_d                      = state_q;
    miss_context_d               = miss_context_q;
    clean_operation_d            = clean_operation_q;
    active_set_index_d           = active_set_index_q;
    active_way_index_d           = active_way_index_q;
    victim_tag_d                 = victim_tag_q;
    victim_word_index_d          = victim_word_index_q;
    victim_line_data_d           = victim_line_data_q;
    requested_word_data_d        = requested_word_data_q;
    transaction_access_fault_d   = transaction_access_fault_q;
    clean_access_fault_d         = clean_access_fault_q;
    writeback_response_pending_d = writeback_response_pending_q;

    // dirty miss期间B响应可能在INVALIDATE、SEND_REFILL或RECEIVE_REFILL任一状态返回。
    // 先统一保存结果，再由当前状态决定何时提交line或异常响应。
    if (writeback_resp_handshake) begin
      writeback_response_pending_d = 1'b0;
      if (writeback_resp_i.access_fault) begin
        if (clean_operation_q)
          clean_access_fault_d = 1'b1;
        else begin
          transaction_access_fault_d = 1'b1;
        end
      end
    end

    unique case (state_q)
      MISS_IDLE: begin
        transaction_access_fault_d   = 1'b0;
        clean_access_fault_d         = 1'b0;
        writeback_response_pending_d = 1'b0;
        victim_word_index_d          = '0;
        if (clean_req_handshake) begin
          clean_operation_d  = 1'b1;
          active_set_index_d = clean_set_index_i;
          active_way_index_d = clean_way_index_i;
          victim_tag_d       = clean_tag_i;
          state_d            = MISS_READ_VICTIM_WORD;
        end else if (miss_req_handshake) begin
          clean_operation_d  = 1'b0;
          miss_context_d     = miss_req_i;
          active_set_index_d = miss_req_i.set_index;
          active_way_index_d = miss_req_i.replacement_way_index;
          victim_tag_d       = miss_req_i.victim_tag;
          state_d            = (miss_req_i.victim_present && miss_req_i.victim_dirty) ?
                    MISS_READ_VICTIM_WORD : MISS_SEND_REFILL;
        end
      end

      MISS_READ_VICTIM_WORD: begin
        state_d = MISS_CAPTURE_VICTIM_WORD;
      end

      MISS_CAPTURE_VICTIM_WORD: begin
        victim_line_data_d[int'(victim_word_index_q)*CORE_DATA_WIDTH+:CORE_DATA_WIDTH] =
            victim_read_word_data_array_i[active_way_index_q];
        if (victim_last_word) begin
          state_d = MISS_SEND_WRITEBACK;
        end else begin
          victim_word_index_d = victim_word_index_q + dcache_word_index_t'(1);
          state_d             = MISS_CAPTURE_VICTIM_WORD;
        end
      end

      MISS_SEND_WRITEBACK: begin
        if (writeback_req_handshake) begin
          writeback_response_pending_d = 1'b1;
          // clean必须等B响应后才能清dirty；普通miss可立即使用独立AR/R通道refill。
          state_d = clean_operation_q ? MISS_WAIT_WRITEBACK_RESPONSE :
              MISS_SEND_REFILL;
        end
      end

      MISS_WAIT_WRITEBACK_RESPONSE: begin
        if (writeback_resp_handshake) begin
          if (clean_operation_q) begin
            if (writeback_resp_i.access_fault) begin
              clean_access_fault_d = 1'b1;
              state_d              = MISS_COMPLETE_CLEAN;
            end else begin
              state_d = MISS_UPDATE_CLEAN_METADATA;
            end
          end else begin
            state_d = transaction_fault_after_bus_handshakes ? MISS_RETURN_RESPONSE :
                MISS_INSTALL_LINE;
          end
        end
      end

      MISS_SEND_REFILL: begin
        if (refill_req_handshake)
          state_d = MISS_RECEIVE_REFILL;
      end

      MISS_RECEIVE_REFILL: begin
        if (refill_resp_handshake) begin
          transaction_access_fault_d = transaction_fault_after_bus_handshakes;
          if (refill_resp_i.word_index == miss_context_q.word_index) begin
            requested_word_data_d = refill_word_after_store_merge;
          end
          if (refill_resp_i.last_word) begin
            if (!writeback_response_completed_after_handshake) begin
              state_d = MISS_WAIT_WRITEBACK_RESPONSE;
            end else begin
              state_d = transaction_fault_after_bus_handshakes ?
                        MISS_RETURN_RESPONSE :
                        MISS_INSTALL_LINE;
            end
          end
        end
      end

      MISS_INSTALL_LINE: begin
        state_d = miss_resp_ready_i ? MISS_IDLE : MISS_RETURN_RESPONSE;
      end

      MISS_RETURN_RESPONSE: begin
        if (miss_resp_valid_o && miss_resp_ready_i)
          state_d = MISS_IDLE;
      end

      MISS_UPDATE_CLEAN_METADATA: begin
        state_d = MISS_IDLE;
      end

      MISS_COMPLETE_CLEAN: begin
        state_d = MISS_IDLE;
      end

      default: state_d = MISS_IDLE;
    endcase
  end

  // 第三段：控制状态、地址身份、line buffer和异常状态分组更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      state_q <= MISS_IDLE;
    else
      state_q <= state_d;
  end

  always_ff @(posedge clk_i) begin
    miss_context_q        <= miss_context_d;
    active_set_index_q    <= active_set_index_d;
    active_way_index_q    <= active_way_index_d;
    victim_tag_q          <= victim_tag_d;
    victim_word_index_q   <= victim_word_index_d;
    victim_line_data_q    <= victim_line_data_d;
    requested_word_data_q <= requested_word_data_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      clean_operation_q            <= 1'b0;
      transaction_access_fault_q   <= 1'b0;
      clean_access_fault_q         <= 1'b0;
      writeback_response_pending_q <= 1'b0;
    end else begin
      clean_operation_q            <= clean_operation_d;
      transaction_access_fault_q   <= transaction_access_fault_d;
      clean_access_fault_q         <= clean_access_fault_d;
      writeback_response_pending_q <= writeback_response_pending_d;
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    !(miss_req_valid_i && clean_req_valid_i))
  else
    $error("D-cache miss and clean requests were presented together");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    metadata_write_line_dirty_o |-> metadata_write_line_present_o)
  else
    $error("D-cache attempted to create a dirty invalid line");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    refill_resp_handshake && refill_resp_i.last_word |->
      (refill_resp_i.word_index == dcache_word_index_t'(DCACHE_WORDS_PER_LINE - 1)))
  else
    $error("D-cache refill RLAST arrived at an unexpected word index");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    state_q == MISS_INSTALL_LINE |->
      (!writeback_response_pending_q && !transaction_access_fault_q))
  else
    $error("D-cache installed a line before all bus responses completed successfully");

`endif

endmodule
