// 参数化、2-way可配置、write-back/write-allocate的阻塞式L1 D-cache。
//
// 同步阵列查询 → 命中响应/缺失请求 → clean 遍历 → 阵列端口选择 → miss/AXI。
// 每次只处理一个缺失；命中响应完成时可接收下一请求，store 同址读由显式旁路处理。
module riscv32_dcache
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
  import riscv32_axi4_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    input  data_memory_req_t  data_memory_req_i,
    input  logic              data_memory_req_valid_i,
    output logic              data_memory_req_ready_o,
    output data_memory_resp_t data_memory_resp_o,
    output logic              data_memory_resp_valid_o,
    input  logic              data_memory_resp_ready_i,

    input  logic clean_req_i,
    output logic clean_done_o,
    output logic clean_access_fault_o,
    output logic cache_busy_o,

    output dcache_event_t event_o,

    output axi4_manager_to_target_t axi_manager_o,
    input  axi4_target_to_manager_t axi_manager_i
);

  function automatic dcache_set_index_t get_set_index(input phys_addr_t addr);
    if (DCACHE_SET_INDEX_BITS == 0)
      return '0;
    return dcache_set_index_t'(addr >> DCACHE_LINE_OFFSET_W);
  endfunction

  function automatic dcache_word_index_t get_word_index(input phys_addr_t addr);
    if (DCACHE_WORD_INDEX_BITS == 0)
      return '0;
    return dcache_word_index_t'(addr >> $clog2(DCACHE_WORD_BYTES));
  endfunction

  function automatic dcache_tag_t get_tag(input phys_addr_t addr);
    return dcache_tag_t'(addr >> (DCACHE_LINE_OFFSET_W + DCACHE_SET_INDEX_BITS));
  endfunction

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

  logic                        tag_read_enable;
  dcache_set_index_t           tag_read_set_index;
  dcache_tag_t                 array_read_tag_array[DCACHE_WAY_COUNT];
  logic [DCACHE_WAY_COUNT-1:0] array_read_line_present_vector;
  logic [DCACHE_WAY_COUNT-1:0] array_read_line_dirty_vector;

  logic               data_read_enable;
  dcache_set_index_t  data_read_set_index;
  dcache_word_index_t data_read_word_index;
  core_data_t         array_read_word_data_array[DCACHE_WAY_COUNT];

  logic               data_write_valid;
  dcache_set_index_t  data_write_set_index;
  dcache_way_index_t  data_write_way_index;
  dcache_word_index_t data_write_word_index;
  core_data_t         data_write_word_data;
  core_byte_strobe_t  data_write_byte_strobe;

  logic              metadata_write_valid;
  dcache_set_index_t metadata_write_set_index;
  dcache_way_index_t metadata_write_way_index;
  dcache_tag_t       metadata_write_tag;
  logic              metadata_write_line_present;
  logic              metadata_write_line_dirty;

  riscv32_dcache_tag_array u_tag_array (
      .clk_i                         (clk_i),
      .rst_ni                        (rst_ni),
      .read_enable_i                 (tag_read_enable),
      .read_set_index_i              (tag_read_set_index),
      .read_tag_array_o              (array_read_tag_array),
      .read_line_present_vector_o    (array_read_line_present_vector),
      .read_line_dirty_vector_o      (array_read_line_dirty_vector),
      .metadata_write_valid_i        (metadata_write_valid),
      .metadata_write_set_index_i    (metadata_write_set_index),
      .metadata_write_way_index_i    (metadata_write_way_index),
      .metadata_write_tag_i          (metadata_write_tag),
      .metadata_write_line_present_i (metadata_write_line_present),
      .metadata_write_line_dirty_i   (metadata_write_line_dirty)
  );

  riscv32_dcache_data_array u_data_array (
      .clk_i                  (clk_i),
      .read_enable_i          (data_read_enable),
      .read_set_index_i       (data_read_set_index),
      .read_word_index_i      (data_read_word_index),
      .read_word_data_array_o (array_read_word_data_array),
      .write_valid_i          (data_write_valid),
      .write_set_index_i      (data_write_set_index),
      .write_way_index_i      (data_write_way_index),
      .write_word_index_i     (data_write_word_index),
      .write_word_data_i      (data_write_word_data),
      .write_byte_strobe_i    (data_write_byte_strobe)
  );

  // miss unit拥有dirty victim读取、writeback和refill期间的array端口。
  dcache_miss_req_t   miss_req;
  logic               miss_req_valid;
  logic               miss_req_ready;
  data_memory_resp_t  miss_resp;
  logic               miss_resp_valid;
  logic               miss_resp_ready;
  logic               miss_transaction_present;
  logic               miss_victim_read_enable;
  dcache_set_index_t  miss_victim_read_set_index;
  dcache_word_index_t miss_victim_read_word_index;
  logic               miss_data_write_valid;
  dcache_set_index_t  miss_data_write_set_index;
  dcache_way_index_t  miss_data_write_way_index;
  dcache_word_index_t miss_data_write_word_index;
  core_data_t         miss_data_write_word_data;
  core_byte_strobe_t  miss_data_write_byte_strobe;
  logic               miss_metadata_write_valid;
  dcache_set_index_t  miss_metadata_write_set_index;
  dcache_way_index_t  miss_metadata_write_way_index;
  dcache_tag_t        miss_metadata_write_tag;
  logic               miss_metadata_write_line_present;
  logic               miss_metadata_write_line_dirty;

  dcache_refill_req_t     refill_req;
  logic                   refill_req_valid;
  logic                   refill_req_ready;
  dcache_refill_resp_t    refill_resp;
  logic                   refill_resp_valid;
  logic                   refill_resp_ready;
  dcache_line_data_t      writeback_line_data;
  dcache_writeback_req_t  writeback_req;
  logic                   writeback_req_valid;
  logic                   writeback_req_ready;
  dcache_writeback_resp_t writeback_resp;
  logic                   writeback_resp_valid;
  logic                   writeback_resp_ready;

  // clean遍历每个set/way；只有dirty line进入miss unit执行writeback。
  typedef enum logic [2:0] {
    CLEAN_IDLE,
    CLEAN_READ_SET,
    CLEAN_CHECK_WAY,
    CLEAN_WAIT_WRITEBACK,
    CLEAN_COMPLETE
  } clean_state_e;

  clean_state_e      clean_state_q, clean_state_d;
  dcache_set_index_t clean_set_index_q, clean_set_index_d;
  dcache_way_index_t clean_way_index_q, clean_way_index_d;
  logic clean_engine_req_valid;
  logic clean_engine_req_ready;
  logic clean_engine_done;
  logic clean_engine_access_fault;
  logic              clean_access_fault_q, clean_access_fault_d;
  logic clean_blocks_lookup;
  logic clean_current_line_dirty;

  assign clean_blocks_lookup = clean_req_i || (clean_state_q != CLEAN_IDLE);
  assign clean_current_line_dirty =
      array_read_line_present_vector[clean_way_index_q] &&
      array_read_line_dirty_vector[clean_way_index_q];
  assign clean_engine_req_valid = (clean_state_q == CLEAN_CHECK_WAY) &&
      clean_current_line_dirty;

  // S0握手同时启动同步array read；S1保存请求身份并在下一拍完成tag compare。
  data_memory_req_t lookup_s1_q;
  logic             lookup_s1_present_q, lookup_s1_present_d;
  logic             lookup_req_handshake;

  logic [DCACHE_WAY_COUNT-1:0] lookup_way_hit_vector;
  logic [DCACHE_WAY_COUNT-1:0] lookup_line_dirty_vector;
  logic                        lookup_hit;
  dcache_way_index_t           lookup_hit_way_index;
  core_data_t                  lookup_hit_word_data;
  dcache_way_index_t           replacement_way_index;
  logic                        replacement_invalid_way_found;

  // store hit写array的同拍允许下一请求启动同步读。宏的read-during-write语义可能是
  // old-data，因此显式保存刚提交的store，并只在紧随其后的S1访问中覆盖对应byte。
  // 同set不同tag的下一请求若miss，也必须看到该way已经变dirty，避免替换时漏写回。
  logic               store_write_bypass_present_q;
  dcache_set_index_t  store_write_bypass_set_index_q;
  dcache_way_index_t  store_write_bypass_way_index_q;
  dcache_word_index_t store_write_bypass_word_index_q;
  core_data_t         store_write_bypass_data_q;
  core_byte_strobe_t  store_write_bypass_byte_strobe_q;
  logic               store_write_bypass_matches_lookup_line;
  logic               store_write_bypass_matches_lookup_word;

  assign store_write_bypass_matches_lookup_line =
      store_write_bypass_present_q &&
      (store_write_bypass_set_index_q == get_set_index(lookup_s1_q.addr));
  assign store_write_bypass_matches_lookup_word =
      store_write_bypass_matches_lookup_line &&
      (store_write_bypass_word_index_q == get_word_index(lookup_s1_q.addr));

  always_comb begin
    lookup_way_hit_vector    = '0;
    lookup_line_dirty_vector = array_read_line_dirty_vector;
    if (store_write_bypass_matches_lookup_line) begin
      lookup_line_dirty_vector[store_write_bypass_way_index_q] = 1'b1;
    end
    lookup_hit           = 1'b0;
    lookup_hit_way_index = '0;
    lookup_hit_word_data = '0;
    for (int unsigned way_index = 0; way_index < DCACHE_WAY_COUNT; way_index++) begin
      lookup_way_hit_vector[way_index] = lookup_s1_present_q &&
          array_read_line_present_vector[way_index] &&
          (array_read_tag_array[way_index] ==
          get_tag(lookup_s1_q.addr));
      if (!lookup_hit && lookup_way_hit_vector[way_index]) begin
        lookup_hit           = 1'b1;
        lookup_hit_way_index = dcache_way_index_t'(way_index);
        lookup_hit_word_data = array_read_word_data_array[way_index];
        if (store_write_bypass_matches_lookup_word &&
            store_write_bypass_way_index_q == dcache_way_index_t'(way_index)) begin
          lookup_hit_word_data = merge_store_bytes(
              array_read_word_data_array[way_index],
              store_write_bypass_data_q,
              store_write_bypass_byte_strobe_q
          );
        end
      end
    end
  end

  // round-robin指针只在成功安装新line后推进；miss选择时永远优先使用invalid way。
  dcache_way_index_t replacement_way_index_array_q[DCACHE_SET_COUNT];
  logic              line_install_event;
  dcache_set_index_t installed_set_index;
  dcache_way_index_t installed_way_index;

  always_comb begin
    replacement_way_index         = replacement_way_index_array_q[get_set_index(lookup_s1_q.addr)];
    replacement_invalid_way_found = 1'b0;
    for (int unsigned way_index = 0; way_index < DCACHE_WAY_COUNT; way_index++) begin
      if (!replacement_invalid_way_found && !array_read_line_present_vector[way_index]) begin
        replacement_way_index         = dcache_way_index_t'(way_index);
        replacement_invalid_way_found = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned set_index = 0; set_index < DCACHE_SET_COUNT; set_index++) begin
        replacement_way_index_array_q[set_index] <= '0;
      end
    end else if (line_install_event) begin
      replacement_way_index_array_q[installed_set_index] <=
          (installed_way_index == dcache_way_index_t'(DCACHE_WAY_COUNT - 1)) ? '0 :
          installed_way_index + dcache_way_index_t'(1);
    end
  end

  // 本地hit响应和miss响应不会同时出现。store hit只在响应握手时写array，避免上游
  // 反压期间重复产生副作用；同拍接收的下一请求由 store bypass 处理读写冲突。
  logic              local_resp_valid;
  data_memory_resp_t local_resp;
  logic              local_resp_handshake;
  logic              miss_req_handshake;
  logic              store_hit_write_event;

  always_comb begin
    local_resp                = '0;
    local_resp.read_data      = lookup_hit_word_data;
    local_resp.transaction_id = lookup_s1_q.transaction_id;
    local_resp_valid          = lookup_s1_present_q && lookup_hit;

    data_memory_resp_o       = local_resp;
    data_memory_resp_valid_o = local_resp_valid;
    miss_resp_ready          = 1'b0;
    if (miss_resp_valid) begin
      data_memory_resp_o       = miss_resp;
      data_memory_resp_valid_o = 1'b1;
      miss_resp_ready          = data_memory_resp_ready_i;
    end
  end

  assign local_resp_handshake  = local_resp_valid && data_memory_resp_ready_i && !miss_resp_valid;
  assign store_hit_write_event = local_resp_handshake &&
      lookup_s1_q.cmd == MEM_CMD_STORE;

  always_comb begin
    miss_req                       = '0;
    miss_req.memory_req            = lookup_s1_q;
    miss_req.set_index             = get_set_index(lookup_s1_q.addr);
    miss_req.word_index            = get_word_index(lookup_s1_q.addr);
    miss_req.requested_tag         = get_tag(lookup_s1_q.addr);
    miss_req.replacement_way_index = replacement_way_index;
    miss_req.victim_tag            = array_read_tag_array[replacement_way_index];
    miss_req.victim_present        = array_read_line_present_vector[replacement_way_index];
    miss_req.victim_dirty          = lookup_line_dirty_vector[replacement_way_index];
    miss_req_valid                 = lookup_s1_present_q && !lookup_hit && !clean_blocks_lookup;
  end
  assign miss_req_handshake = miss_req_valid && miss_req_ready;

  // 所有hit响应都允许同拍启动下一lookup。store后的显式bypass定义了SRAM
  // read-during-write行为，因此连续load/store不再为了宏语义固定空转一拍。
  assign data_memory_req_ready_o =
      (!lookup_s1_present_q || local_resp_handshake) &&
      !miss_transaction_present && !clean_blocks_lookup;
  assign lookup_req_handshake = data_memory_req_valid_i && data_memory_req_ready_o;

  always_comb begin
    lookup_s1_present_d = lookup_s1_present_q;
    if (miss_req_handshake) begin
      lookup_s1_present_d = 1'b0;
    end else if (data_memory_req_ready_o) begin
      lookup_s1_present_d = lookup_req_handshake;
    end
  end

  always_ff @(posedge clk_i) begin
    if (lookup_req_handshake)
      lookup_s1_q <= data_memory_req_i;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      lookup_s1_present_q <= 1'b0;
    else
      lookup_s1_present_q <= lookup_s1_present_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      store_write_bypass_present_q <= 1'b0;
    end else if (lookup_req_handshake || !lookup_s1_present_d) begin
      store_write_bypass_present_q <= store_hit_write_event && lookup_req_handshake;
      if (store_hit_write_event && lookup_req_handshake) begin
        store_write_bypass_set_index_q   <= get_set_index(lookup_s1_q.addr);
        store_write_bypass_way_index_q   <= lookup_hit_way_index;
        store_write_bypass_word_index_q  <= get_word_index(lookup_s1_q.addr);
        store_write_bypass_data_q        <= lookup_s1_q.write_data;
        store_write_bypass_byte_strobe_q <= lookup_s1_q.byte_strobe;
      end
    end
  end

  always_comb begin
    clean_done_o         = clean_state_q == CLEAN_COMPLETE;
    clean_access_fault_o = clean_access_fault_q;
  end

  always_comb begin
    clean_state_d        = clean_state_q;
    clean_set_index_d    = clean_set_index_q;
    clean_way_index_d    = clean_way_index_q;
    clean_access_fault_d = clean_access_fault_q;

    unique case (clean_state_q)
      CLEAN_IDLE: begin
        clean_access_fault_d = 1'b0;
        if (clean_req_i) begin
          clean_set_index_d = '0;
          clean_way_index_d = '0;
          clean_state_d     = CLEAN_READ_SET;
        end
      end

      CLEAN_READ_SET: clean_state_d = CLEAN_CHECK_WAY;

      CLEAN_CHECK_WAY: begin
        if (clean_current_line_dirty) begin
          if (clean_engine_req_valid && clean_engine_req_ready) begin
            clean_state_d = CLEAN_WAIT_WRITEBACK;
          end
        end else if (clean_way_index_q == dcache_way_index_t'(DCACHE_WAY_COUNT - 1)) begin
          clean_way_index_d = '0;
          if (clean_set_index_q == dcache_set_index_t'(DCACHE_SET_COUNT - 1)) begin
            clean_state_d = CLEAN_COMPLETE;
          end else begin
            clean_set_index_d = clean_set_index_q + dcache_set_index_t'(1);
            clean_state_d     = CLEAN_READ_SET;
          end
        end else begin
          clean_way_index_d = clean_way_index_q + dcache_way_index_t'(1);
        end
      end

      CLEAN_WAIT_WRITEBACK: begin
        if (clean_engine_done) begin
          clean_access_fault_d = clean_access_fault_q || clean_engine_access_fault;
          if (clean_engine_access_fault) begin
            clean_state_d = CLEAN_COMPLETE;
          end else if (clean_way_index_q == dcache_way_index_t'(DCACHE_WAY_COUNT - 1)) begin
            clean_way_index_d = '0;
            if (clean_set_index_q == dcache_set_index_t'(DCACHE_SET_COUNT - 1)) begin
              clean_state_d = CLEAN_COMPLETE;
            end else begin
              clean_set_index_d = clean_set_index_q + dcache_set_index_t'(1);
              clean_state_d     = CLEAN_READ_SET;
            end
          end else begin
            clean_way_index_d = clean_way_index_q + dcache_way_index_t'(1);
            clean_state_d     = CLEAN_CHECK_WAY;
          end
        end
      end

      CLEAN_COMPLETE: clean_state_d = CLEAN_IDLE;
      default: clean_state_d = CLEAN_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      clean_state_q <= CLEAN_IDLE;
    else
      clean_state_q <= clean_state_d;
  end

  always_ff @(posedge clk_i) begin
    clean_set_index_q <= clean_set_index_d;
    clean_way_index_q <= clean_way_index_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      clean_access_fault_q <= 1'b0;
    else
      clean_access_fault_q <= clean_access_fault_d;
  end

  // S1 请求与同步读输出一起保持，只有接收新请求才能覆盖 lookup 数据。
  // clean 扫描优先使用 tag 口，victim 采集优先使用 data 口。
  always_comb begin
    tag_read_enable    = lookup_req_handshake;
    tag_read_set_index = get_set_index(data_memory_req_i.addr);
    if (clean_state_q == CLEAN_READ_SET) begin
      tag_read_enable    = 1'b1;
      tag_read_set_index = clean_set_index_q;
    end else if (clean_state_q != CLEAN_IDLE) begin
      tag_read_enable = 1'b0;
    end

    data_read_enable     = lookup_req_handshake;
    data_read_set_index  = get_set_index(data_memory_req_i.addr);
    data_read_word_index = get_word_index(data_memory_req_i.addr);
    if (miss_victim_read_enable) begin
      data_read_enable     = 1'b1;
      data_read_set_index  = miss_victim_read_set_index;
      data_read_word_index = miss_victim_read_word_index;
    end
  end

  // miss/refill写口优先；正常store hit只会在miss unit空闲时发生。
  always_comb begin
    data_write_valid      = miss_data_write_valid;
    data_write_set_index  = miss_data_write_set_index;
    data_write_way_index  = miss_data_write_way_index;
    data_write_word_index = miss_data_write_word_index;
    // 数据选择不等待命中/响应握手；真正写入仍由下方 valid 严格限定。
    // miss/refill 优先，未写入时 store 数据只是未被采样的默认载荷。
    data_write_word_data = miss_data_write_valid ? miss_data_write_word_data :
        lookup_s1_q.write_data;
    data_write_byte_strobe = miss_data_write_byte_strobe;
    if (!miss_data_write_valid && store_hit_write_event) begin
      data_write_valid       = 1'b1;
      data_write_set_index   = get_set_index(lookup_s1_q.addr);
      data_write_way_index   = lookup_hit_way_index;
      data_write_word_index  = get_word_index(lookup_s1_q.addr);
      data_write_byte_strobe = lookup_s1_q.byte_strobe;
    end
  end

  always_comb begin
    metadata_write_valid        = miss_metadata_write_valid;
    metadata_write_set_index    = miss_metadata_write_set_index;
    metadata_write_way_index    = miss_metadata_write_way_index;
    metadata_write_tag          = miss_metadata_write_tag;
    metadata_write_line_present = miss_metadata_write_line_present;
    metadata_write_line_dirty   = miss_metadata_write_line_dirty;
    if (!miss_metadata_write_valid && store_hit_write_event) begin
      metadata_write_valid        = 1'b1;
      metadata_write_set_index    = get_set_index(lookup_s1_q.addr);
      metadata_write_way_index    = lookup_hit_way_index;
      metadata_write_tag          = get_tag(lookup_s1_q.addr);
      metadata_write_line_present = 1'b1;
      metadata_write_line_dirty   = 1'b1;
    end
  end

  riscv32_dcache_miss_unit u_miss_unit (
      .clk_i                         (clk_i),
      .rst_ni                        (rst_ni),
      .miss_req_i                    (miss_req),
      .miss_req_valid_i              (miss_req_valid),
      .miss_req_ready_o              (miss_req_ready),
      .miss_resp_o                   (miss_resp),
      .miss_resp_valid_o             (miss_resp_valid),
      .miss_resp_ready_i             (miss_resp_ready),
      .clean_set_index_i             (clean_set_index_q),
      .clean_way_index_i             (clean_way_index_q),
      .clean_tag_i                   (array_read_tag_array[clean_way_index_q]),
      .clean_req_valid_i             (clean_engine_req_valid),
      .clean_req_ready_o             (clean_engine_req_ready),
      .clean_done_o                  (clean_engine_done),
      .clean_access_fault_o          (clean_engine_access_fault),
      .victim_read_enable_o          (miss_victim_read_enable),
      .victim_read_set_index_o       (miss_victim_read_set_index),
      .victim_read_word_index_o      (miss_victim_read_word_index),
      .victim_read_word_data_array_i (array_read_word_data_array),
      .data_write_valid_o            (miss_data_write_valid),
      .data_write_set_index_o        (miss_data_write_set_index),
      .data_write_way_index_o        (miss_data_write_way_index),
      .data_write_word_index_o       (miss_data_write_word_index),
      .data_write_word_data_o        (miss_data_write_word_data),
      .data_write_byte_strobe_o      (miss_data_write_byte_strobe),
      .metadata_write_valid_o        (miss_metadata_write_valid),
      .metadata_write_set_index_o    (miss_metadata_write_set_index),
      .metadata_write_way_index_o    (miss_metadata_write_way_index),
      .metadata_write_tag_o          (miss_metadata_write_tag),
      .metadata_write_line_present_o (miss_metadata_write_line_present),
      .metadata_write_line_dirty_o   (miss_metadata_write_line_dirty),
      .line_install_event_o          (line_install_event),
      .installed_set_index_o         (installed_set_index),
      .installed_way_index_o         (installed_way_index),
      .transaction_present_o         (miss_transaction_present),
      .refill_req_o                  (refill_req),
      .refill_req_valid_o            (refill_req_valid),
      .refill_req_ready_i            (refill_req_ready),
      .refill_resp_i                 (refill_resp),
      .refill_resp_valid_i           (refill_resp_valid),
      .refill_resp_ready_o           (refill_resp_ready),
      .writeback_line_data_o          (writeback_line_data),
      .writeback_req_o               (writeback_req),
      .writeback_req_valid_o         (writeback_req_valid),
      .writeback_req_ready_i         (writeback_req_ready),
      .writeback_resp_i              (writeback_resp),
      .writeback_resp_valid_i        (writeback_resp_valid),
      .writeback_resp_ready_o        (writeback_resp_ready)
  );

  riscv32_dcache_axi u_dcache_axi (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .refill_req_i           (refill_req),
      .refill_req_valid_i     (refill_req_valid),
      .refill_req_ready_o     (refill_req_ready),
      .refill_resp_o          (refill_resp),
      .refill_resp_valid_o    (refill_resp_valid),
      .refill_resp_ready_i    (refill_resp_ready),
      .writeback_line_data_i          (writeback_line_data),
      .writeback_req_i        (writeback_req),
      .writeback_req_valid_i  (writeback_req_valid),
      .writeback_req_ready_o  (writeback_req_ready),
      .writeback_resp_o       (writeback_resp),
      .writeback_resp_valid_o (writeback_resp_valid),
      .writeback_resp_ready_i (writeback_resp_ready),
      .axi_manager_o          (axi_manager_o),
      .axi_manager_i          (axi_manager_i)
  );

  assign cache_busy_o = lookup_s1_present_q || miss_transaction_present || clean_blocks_lookup;

  // 性能事件直接取自协议握手和cache状态动作。保持这组信号为纯观察路径，既能
  // 区分命中延迟与缺失代价，也不会把监视器引入功能或时序控制。
  always_comb begin
    event_o                              = '0;
    event_o.lookup_event                 = lookup_req_handshake;
    event_o.lookup_is_store              = data_memory_req_i.cmd == MEM_CMD_STORE;
    event_o.lookup_response_present      = data_memory_resp_valid_o;
    event_o.lookup_response_is_cache_hit = local_resp_valid && !miss_resp_valid;
    event_o.lookup_request_waiting       = data_memory_req_valid_i &&
        !data_memory_req_ready_o;
    event_o.store_hit_and_next_lookup_event = store_hit_write_event &&
        lookup_req_handshake;
    event_o.miss_event              = miss_req_handshake;
    event_o.dirty_victim_miss_event = miss_req_handshake &&
        miss_req.victim_present &&
        miss_req.victim_dirty;
    event_o.refill_request_event               = refill_req_valid && refill_req_ready;
    event_o.refill_word_event                  = refill_resp_valid && refill_resp_ready;
    event_o.refill_transaction_completed_event = refill_resp_valid &&
        refill_resp_ready &&
        refill_resp.last_word;
    event_o.line_install_event      = line_install_event;
    event_o.writeback_request_event = writeback_req_valid &&
        writeback_req_ready;
    event_o.writeback_response_event = writeback_resp_valid &&
        writeback_resp_ready;
  end

`ifndef SYNTHESIS
  initial begin
    assert (DCACHE_CAPACITY_BYTES > 0)
      else
        $fatal(1, "D-cache capacity must be positive");
    assert (DCACHE_WAY_COUNT > 0)
      else
        $fatal(1, "D-cache way count must be positive");
    assert ((DCACHE_LINE_BYTES & (DCACHE_LINE_BYTES - 1)) == 0)
      else
        $fatal(1, "D-cache line bytes must be a power of two");
    assert ((DCACHE_SET_COUNT & (DCACHE_SET_COUNT - 1)) == 0)
      else
        $fatal(1, "D-cache set count must be a power of two");
  end

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    data_memory_req_valid_i && !data_memory_req_ready_o |=>
      (data_memory_req_valid_i && $stable(data_memory_req_i)))
  else
    $error("D-cache request changed while stalled");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    data_memory_resp_valid_o && !data_memory_resp_ready_i |=>
      (data_memory_resp_valid_o && $stable(data_memory_resp_o)))
  else
    $error("D-cache response changed while stalled");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    $onehot0(lookup_way_hit_vector))
  else
    $error("D-cache found the same line in multiple ways");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    lookup_req_handshake |-> (tag_read_enable && data_read_enable))
  else
    $error("D-cache accepted a lookup without sampling both arrays");
`endif

endmodule
