// 阻塞式 L1 I-cache：同步读阵列与请求寄存对齐，下一拍比较 tag 并返回 hit。
// miss 独占下层回填；关键 word 可提前返回，但整行完成前不接收新 lookup。
// 源码按阵列端口、查询级、invalidate 状态机、事件与断言组织。
module riscv32_icache
  import riscv32_pkg::*;
  // 地址拆分函数直接处理物理地址，因此显式依赖地址映射package。
  import riscv32_addr_map_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  icache_lookup_req_t  lookup_req_i,
    input  logic                lookup_req_valid_i,
    output logic                lookup_req_ready_o,
    output icache_lookup_resp_t lookup_resp_o,
    output logic                lookup_resp_valid_o,
    input  logic                lookup_resp_ready_i,

    input  logic invalidate_req_i,
    output logic invalidate_done_o,
    output logic cache_busy_o,

    // I-cache只表达“请求一组word、逐word接收响应”的本地refill语义。
    // 完整AXI4的ID、LEN、SIZE、BURST和RLAST由边界adapter负责。
    output icache_refill_req_t  refill_req_o,
    output logic                refill_req_valid_o,
    input  logic                refill_req_ready_i,
    input  icache_refill_resp_t refill_resp_i,
    input  logic                refill_resp_valid_i,
    output logic                refill_resp_ready_o,

    output icache_event_t event_o
);

  // 子模块按访问路径组织：PMA负责物理地址属性，tag/data array负责同步读取，
  // miss unit负责下层访问、critical-word early restart以及逐word回填。I-cache内部
  // 使用refill语义接口，AXI4协议细节保留在cache外部的adapter中。
  pma_attr_t lookup_memory_attr;

  logic                        array_read_enable;
  icache_set_index_t           array_read_set_index;
  icache_word_index_t          array_read_word_index;
  icache_tag_t                 array_read_tag_array[ICACHE_WAY_COUNT];
  logic [ICACHE_WAY_COUNT-1:0] array_read_line_present_vector;
  // 命中数据路径使用fetch宽度，修改XLEN不会无意义地扩大I-cache阵列。
  icache_fetch_data_t array_read_word_data_array[ICACHE_WAY_COUNT];

  icache_miss_req_t    miss_req;
  logic                miss_req_valid;
  logic                miss_req_ready;
  icache_lookup_resp_t miss_lookup_resp;
  logic                miss_lookup_resp_valid;
  logic                miss_lookup_resp_ready;
  logic                miss_transaction_present;
  icache_event_t       miss_unit_events;

  logic               refill_data_write_valid;
  icache_set_index_t  refill_data_write_set_index;
  icache_way_index_t  refill_data_write_way_index;
  icache_word_index_t refill_data_write_word_index;
  icache_fetch_data_t refill_data_write_word_data;

  logic              refill_metadata_write_valid;
  icache_set_index_t refill_metadata_write_set_index;
  icache_way_index_t refill_metadata_write_way_index;
  icache_tag_t       refill_metadata_write_tag;
  logic              refill_metadata_write_line_present;

  logic              metadata_write_valid;
  icache_set_index_t metadata_write_set_index;
  icache_way_index_t metadata_write_way_index;
  icache_tag_t       metadata_write_tag;
  logic              metadata_write_line_present;

  riscv32_pma u_riscv32_pma (
      .lookup_addr_i (lookup_req_i.fetch_addr),
      .memory_attr_o (lookup_memory_attr)
  );

  riscv32_icache_tag_array u_riscv32_icache_tag_array (
      .clk_i                         (clk_i),
      .rst_ni                        (rst_ni),
      .read_enable_i                 (array_read_enable),
      .read_set_index_i              (array_read_set_index),
      .read_tag_array_o              (array_read_tag_array),
      .read_line_present_vector_o    (array_read_line_present_vector),
      .invalidate_all_i              (invalidate_done_o),
      .metadata_write_valid_i        (metadata_write_valid),
      .metadata_write_set_index_i    (metadata_write_set_index),
      .metadata_write_way_index_i    (metadata_write_way_index),
      .metadata_write_tag_i          (metadata_write_tag),
      .metadata_write_line_present_i (metadata_write_line_present)
  );

  riscv32_icache_data_array u_riscv32_icache_data_array (
      .clk_i                     (clk_i),
      .rst_ni                    (rst_ni),
      .read_enable_i             (array_read_enable),
      .read_set_index_i          (array_read_set_index),
      .read_word_index_i         (array_read_word_index),
      .read_word_data_array_o    (array_read_word_data_array),
      .refill_write_valid_i      (refill_data_write_valid),
      .refill_write_set_index_i  (refill_data_write_set_index),
      .refill_write_way_index_i  (refill_data_write_way_index),
      .refill_write_word_index_i (refill_data_write_word_index),
      .refill_write_word_data_i  (refill_data_write_word_data)
  );

  riscv32_icache_miss_unit u_riscv32_icache_miss_unit (
      .clk_i                         (clk_i),
      .rst_ni                        (rst_ni),
      .miss_req_i                    (miss_req),
      .miss_req_valid_i              (miss_req_valid),
      .miss_req_ready_o              (miss_req_ready),
      .lookup_resp_o                 (miss_lookup_resp),
      .lookup_resp_valid_o           (miss_lookup_resp_valid),
      .lookup_resp_ready_i           (miss_lookup_resp_ready),
      .refill_req_o                  (refill_req_o),
      .refill_req_valid_o            (refill_req_valid_o),
      .refill_req_ready_i            (refill_req_ready_i),
      .refill_resp_i                 (refill_resp_i),
      .refill_resp_valid_i           (refill_resp_valid_i),
      .refill_resp_ready_o           (refill_resp_ready_o),
      .data_write_valid_o            (refill_data_write_valid),
      .data_write_set_index_o        (refill_data_write_set_index),
      .data_write_way_index_o        (refill_data_write_way_index),
      .data_write_word_index_o       (refill_data_write_word_index),
      .data_write_word_data_o        (refill_data_write_word_data),
      .metadata_write_valid_o        (refill_metadata_write_valid),
      .metadata_write_set_index_o    (refill_metadata_write_set_index),
      .metadata_write_way_index_o    (refill_metadata_write_way_index),
      .metadata_write_tag_o          (refill_metadata_write_tag),
      .metadata_write_line_present_o (refill_metadata_write_line_present),
      .miss_transaction_present_o    (miss_transaction_present),
      .event_o                       (miss_unit_events)
  );

  // 这些是当前实现的明确几何约束，不是运行时容错。line大小由构建参数选择，所有
  // 地址切片、阵列深度和refill计数必须只依赖package中的派生量。
  initial begin
    if ((ICACHE_WAY_COUNT & (ICACHE_WAY_COUNT - 1)) != 0) begin
      $fatal(1, "I-cache way count must be a power of two");
    end
    if (ICACHE_CAPACITY_BYTES == 0 || ICACHE_LINE_BYTES == 0) begin
      $fatal(1, "I-cache capacity and line size must be non-zero");
    end
    if ((ICACHE_CAPACITY_BYTES % (ICACHE_WAY_COUNT * ICACHE_LINE_BYTES)) != 0) begin
      $fatal(1, "I-cache capacity must contain an integer number of sets");
    end
    if ((ICACHE_SET_COUNT & (ICACHE_SET_COUNT - 1)) != 0) begin
      $fatal(1, "I-cache set count must be a power of two");
    end
    if ((ICACHE_LINE_BYTES & (ICACHE_LINE_BYTES - 1)) != 0) begin
      $fatal(1, "I-cache line size must be a power of two");
    end
    if ((ICACHE_LINE_BYTES % ICACHE_FETCH_BYTES) != 0) begin
      $fatal(1, "I-cache line size must contain an integer number of fetch words");
    end
    if (ICACHE_WORDS_PER_LINE > 256) begin
      $fatal(1, "I-cache refill exceeds the AXI4 ARLEN limit");
    end
  end
  // Lookup流水线：S0是输入握手与同步阵列读请求；S1保存请求身份和PMA属性，
  // tag/data array内部的同步读寄存器在同一时钟沿保存对应阵列数据。下一拍直接使用
  // S1身份和阵列输出执行命中判断，不再增加一份内容完全相同的S2快照。
  // present表示S1持有有效请求，ready表示该请求已完成或级内为空。miss调度当拍
  // 禁止接收年轻请求，保证单MSHR阻塞式I-cache不会产生响应越序。
  icache_lookup_req_t lookup_s1_q, lookup_s1_d;
  // Lookup流水只保存命中分类真正使用的PMA位。idempotent和宽度转换属性属于
  // 数据访问/总线边界，不应随每次取指进入S1寄存器。
  logic lookup_executable_s1_q, lookup_executable_s1_d;
  logic lookup_cacheable_s1_q, lookup_cacheable_s1_d;
  logic lookup_s1_present_q, lookup_s1_present_d;

  logic lookup_req_handshake;
  logic lookup_s1_ready;
  logic lookup_s1_completed;
  logic local_lookup_resp_handshake;
  logic miss_req_handshake;

  // 物理地址按cache几何参数拆成tag、set和行内word索引；单set/单word时索引固定为0。
  function automatic icache_set_index_t get_icache_set_index(input phys_addr_t addr);
    if (ICACHE_SET_INDEX_BITS == 0) begin
      return '0;
    end
    return icache_set_index_t'(addr >> ICACHE_LINE_OFFSET_W);
  endfunction

  function automatic icache_word_index_t get_icache_word_index(input phys_addr_t addr);
    if (ICACHE_WORD_INDEX_BITS == 0) begin
      return '0;
    end
    return icache_word_index_t'(addr >> $clog2(ICACHE_FETCH_BYTES));
  endfunction

  function automatic icache_tag_t get_icache_tag(input phys_addr_t addr);
    return addr[PADDR_WIDTH-1-:ICACHE_TAG_W];
  endfunction

  // S1并行比较全部way的present和tag，并把请求划分为四类互斥结果：
  // access fault、uncached访问、cache hit和cache miss。命中向量按低way优先选择数据；
  // 正常状态下同一set最多只能有一路命中，仿真断言会检查重复tag错误。
  // 四类结果互斥：不可执行地址本地返回fault；可执行但不可缓存地址走单word uncached
  // 访问；cacheable地址命中时本地返回，未命中时请求整line refill。响应反压时S1和
  // array读输出都保持，所以组合payload也保持稳定，无需重复增加response寄存器。
  logic [ICACHE_WAY_COUNT-1:0] lookup_way_hit_vector;
  logic                        lookup_hit;
  icache_fetch_data_t          lookup_hit_word_data;
  logic                        lookup_access_fault;
  logic                        lookup_uncached;
  logic                        lookup_cache_miss;
  icache_way_index_t           replacement_way_index;
  logic                        local_lookup_resp_valid;
  icache_lookup_resp_t         local_lookup_resp;

  always_comb begin
    lookup_way_hit_vector = '0;
    lookup_hit            = 1'b0;
    lookup_hit_word_data  = '0;

    for (int unsigned way_index = 0; way_index < ICACHE_WAY_COUNT; way_index++) begin
      lookup_way_hit_vector[way_index] =
          lookup_s1_present_q && lookup_executable_s1_q && lookup_cacheable_s1_q &&
          array_read_line_present_vector[way_index] &&
          (array_read_tag_array[way_index] == get_icache_tag(lookup_s1_q.fetch_addr));
      if (!lookup_hit && lookup_way_hit_vector[way_index]) begin
        lookup_hit           = 1'b1;
        lookup_hit_word_data = array_read_word_data_array[way_index];
      end
    end

    lookup_access_fault = lookup_s1_present_q && !lookup_executable_s1_q;
    lookup_uncached     = lookup_s1_present_q && lookup_executable_s1_q && !lookup_cacheable_s1_q;
    lookup_cache_miss   =
        lookup_s1_present_q && lookup_executable_s1_q && lookup_cacheable_s1_q && !lookup_hit;

    local_lookup_resp_valid        = lookup_access_fault || lookup_hit;
    local_lookup_resp              = '0;
    local_lookup_resp.fetch_addr   = lookup_s1_q.fetch_addr;
    local_lookup_resp.frontend_tag = lookup_s1_q.frontend_tag;
    local_lookup_resp.fetch_epoch  = lookup_s1_q.fetch_epoch;
    local_lookup_resp.access_fault = lookup_access_fault;
    local_lookup_resp.fetch_data   = lookup_hit ? lookup_hit_word_data : '0;

  end

  // 直接映射配置的victim恒为way 0，不应实例化任何替换状态。组相联配置才为每个set
  // 保存下一次全有效miss的victim way：优先使用invalid way，全部way有效时使用轮转指针。
  // generate在展开期只保留当前配置需要的硬件，不改变I-cache外部协议。
  generate
    if (ICACHE_WAY_COUNT == 1) begin : g_direct_mapped_replacement
      always_comb begin
        replacement_way_index = '0;
      end
    end else begin : g_set_associative_replacement
      icache_way_index_t replacement_way_index_array_q[ICACHE_SET_COUNT];
      logic              replacement_invalid_way_found;

      always_comb begin
        replacement_way_index =
            replacement_way_index_array_q[get_icache_set_index(lookup_s1_q.fetch_addr)];
        replacement_invalid_way_found = 1'b0;

        for (int unsigned way_index = 0; way_index < ICACHE_WAY_COUNT; way_index++) begin
          if (!replacement_invalid_way_found && !array_read_line_present_vector[way_index]) begin
            replacement_way_index         = icache_way_index_t'(way_index);
            replacement_invalid_way_found = 1'b1;
          end
        end
      end

      // 替换状态只在cacheable miss真正被miss unit接收时推进，反压期间不得提前改变。
      always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
          for (int unsigned set_index = 0; set_index < ICACHE_SET_COUNT; set_index++) begin
            replacement_way_index_array_q[set_index] <= '0;
          end
        end else if (miss_req_handshake && miss_req.cacheable) begin
          if (replacement_way_index == icache_way_index_t'(ICACHE_WAY_COUNT - 1)) begin
            replacement_way_index_array_q[get_icache_set_index(lookup_s1_q.fetch_addr)] <= '0;
          end else begin
            replacement_way_index_array_q[get_icache_set_index(lookup_s1_q.fetch_addr)] <=
                replacement_way_index + icache_way_index_t'(1);
          end
        end
      end
    end
  endgenerate
  // 响应路径优先返回miss unit的响应，本地hit/fault响应在其后。lookup流水采用
  // elastic ready/valid推进；阻塞式miss存续期间冻结年轻请求，避免响应越序。
  // critical word可以提前返回IFU，但唯一MSHR仍占用到整条cache line回填结束。
  always_comb begin
    lookup_resp_o          = local_lookup_resp;
    lookup_resp_valid_o    = local_lookup_resp_valid;
    miss_lookup_resp_ready = 1'b0;

    // miss响应优先于本地hit/fault响应；阻塞式设计应保证二者不会同时有效。
    if (miss_lookup_resp_valid) begin
      lookup_resp_o          = miss_lookup_resp;
      lookup_resp_valid_o    = 1'b1;
      miss_lookup_resp_ready = lookup_resp_ready_i;
    end

    miss_req                       = '0;
    miss_req.lookup_req            = lookup_s1_q;
    miss_req.replacement_way_index = replacement_way_index;
    miss_req.cacheable             = lookup_cacheable_s1_q;
    miss_req_valid                 = lookup_s1_present_q && (lookup_cache_miss || lookup_uncached);
    array_read_enable              = lookup_req_handshake;
    array_read_set_index           = get_icache_set_index(lookup_req_i.fetch_addr);
    array_read_word_index          = get_icache_word_index(lookup_req_i.fetch_addr);
  end

  assign local_lookup_resp_handshake =
      local_lookup_resp_valid && lookup_resp_ready_i && !miss_lookup_resp_valid;
  assign miss_req_handshake   = miss_req_valid && miss_req_ready;
  assign lookup_s1_completed  = local_lookup_resp_handshake || miss_req_handshake;
  assign lookup_s1_ready      = (!lookup_s1_present_q || lookup_s1_completed) && !miss_req_valid;
  assign lookup_req_handshake = lookup_req_valid_i && lookup_req_ready_o;

  always_comb begin
    lookup_s1_d            = lookup_s1_q;
    lookup_executable_s1_d = lookup_executable_s1_q;
    lookup_cacheable_s1_d  = lookup_cacheable_s1_q;
    lookup_s1_present_d    = lookup_s1_present_q;

    if (miss_req_handshake) begin
      lookup_s1_present_d = 1'b0;
    end else if (lookup_s1_ready) begin
      lookup_s1_present_d = lookup_req_handshake;
      if (lookup_req_handshake) begin
        lookup_s1_d            = lookup_req_i;
        lookup_executable_s1_d = lookup_memory_attr.executable;
        lookup_cacheable_s1_d  = lookup_memory_attr.cacheable;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      lookup_s1_q            <= '0;
      lookup_executable_s1_q <= 1'b0;
      lookup_cacheable_s1_q  <= 1'b0;
      lookup_s1_present_q    <= 1'b0;
    end else begin
      lookup_s1_q            <= lookup_s1_d;
      lookup_executable_s1_q <= lookup_executable_s1_d;
      lookup_cacheable_s1_q  <= lookup_cacheable_s1_d;
      lookup_s1_present_q    <= lookup_s1_present_d;
    end
  end

  // 维护请求保持到 done。先排空旧查询/refill，再在该握手沿清除全部有效位。
  // 有效位是独立触发器，tag/data 不清零；不为假设的单口宏逐项遍历。
  assign invalidate_done_o = invalidate_req_i && !lookup_s1_present_q &&
      !miss_transaction_present;
  assign cache_busy_o = lookup_s1_present_q || miss_transaction_present || invalidate_req_i;
  assign lookup_req_ready_o = lookup_s1_ready && !miss_transaction_present && !invalidate_req_i;

  assign metadata_write_valid        = refill_metadata_write_valid;
  assign metadata_write_set_index    = refill_metadata_write_set_index;
  assign metadata_write_way_index    = refill_metadata_write_way_index;
  assign metadata_write_tag          = refill_metadata_write_tag;
  assign metadata_write_line_present = refill_metadata_write_line_present;

  // event只观察cache接口和miss-unit事件，不参与cache控制。lookup response使用present
  // 作为AMAT终点；PMU用活动请求状态保证响应反压时不会重复计数。过期fetch epoch由IFU识别，因此
  // stale_response_discarded_event在I-cache内部固定为0。当前event没有access-fault字段，
  // 因此发生取指访问异常时，lookup计数不会落入hit、miss或uncached三类中的任何一类。
  always_comb begin
    event_o                         = '0;
    event_o.lookup_event            = lookup_req_handshake;
    event_o.lookup_response_present = lookup_resp_valid_o;
    event_o.lookup_response_is_cache_hit =
        local_lookup_resp_valid && lookup_hit && !miss_lookup_resp_valid;
    event_o.lookup_request_waiting = lookup_req_valid_i && !lookup_req_ready_o;
    event_o.miss_event             = miss_unit_events.miss_event;
    event_o.uncached_access_event  = miss_req_handshake && lookup_uncached;
    event_o.refill_word_event      = miss_unit_events.refill_word_event;
    event_o.refill_transaction_completed_event =
        miss_unit_events.refill_transaction_completed_event;
    event_o.refill_line_completed_event    = miss_unit_events.refill_line_completed_event;
    event_o.stale_response_discarded_event = 1'b0;
  end

`ifndef SYNTHESIS
  // ready/valid接口被反压时，发送方必须保持valid和payload，直到握手发生。
  a_lookup_request_stable_while_stalled :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (lookup_req_valid_i && !lookup_req_ready_o) |=>
          (lookup_req_valid_i && $stable(lookup_req_i)))
  else $error("I-cache lookup request changed while stalled");

  a_lookup_response_stable_while_stalled :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (lookup_resp_valid_o && !lookup_resp_ready_i) |=>
          (lookup_resp_valid_o && $stable(lookup_resp_o)))
  else $error("I-cache lookup response changed while stalled");

  // 单MSHR设计任意时刻只能由本地路径或miss unit中的一方驱动lookup响应。
  a_local_and_miss_response_are_exclusive :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      !(local_lookup_resp_valid && miss_lookup_resp_valid)
  )
  else $error("I-cache local and miss responses are both valid");

  // 同一个set中不能存在两个present且tag相同的way，否则命中数据会依赖way优先级，
  // 并掩盖refill/invalidate元数据管理错误。
  a_lookup_hits_at_most_one_way :
  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(lookup_way_hit_vector))
  else $error("I-cache lookup matched multiple ways");

  a_miss_request_has_valid_classification :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      miss_req_valid |->
          (lookup_s1_present_q && (lookup_cache_miss || lookup_uncached))
  )
  else $error("I-cache miss request has no valid S1 classification");

  a_array_read_matches_lookup_acceptance :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (array_read_enable == lookup_req_handshake)
  )
  else $error("I-cache array read does not match lookup handshake");

  // invalidate先排空miss，因此refill与invalidate不能同时写metadata array。
  a_metadata_write_sources_are_exclusive :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      !(refill_metadata_write_valid && invalidate_done_o)
  )
  else $error("I-cache refill and invalidate metadata writes conflict");

  a_invalidate_blocks_new_lookup :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      invalidate_req_i |-> !lookup_req_ready_o
  )
  else $error("I-cache accepted lookup during invalidate");

  // present=1只能来自整条line完成安装；present=0可来自miss开始时清victim或invalidate。
  a_present_install_comes_from_refill_completion :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (metadata_write_valid && metadata_write_line_present) |->
          (refill_metadata_write_valid && refill_metadata_write_line_present)
  )
  else $error("I-cache present installation did not come from refill completion");

  a_present_clear_has_valid_source :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (metadata_write_valid && !metadata_write_line_present) |->
          (invalidate_done_o ||
           (refill_metadata_write_valid && !refill_metadata_write_line_present))
  )
  else $error("I-cache present clear has no valid source");

  a_blocking_miss_rejects_new_lookup :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    miss_transaction_present |-> !lookup_req_ready_o)
  else $error("blocking I-cache accepted a younger lookup during refill");

  a_miss_dispatch_freezes_s1 :
  assert property (@(posedge clk_i) disable iff (!rst_ni) miss_req_valid |-> !lookup_s1_ready)
  else $error("I-cache S1 advanced while dispatching a miss");

`endif

  // Directed-test验证清单：每项都应检查握手次数、
  // payload身份、array写次数和event脉冲，不能只比较最终instruction：
  // 1. 冷启动cacheable miss：ICACHE_WORDS_PER_LINE个word逐拍返回，确认逐word
  //    data写和最后一次metadata提交；
  // 2. 同地址再次lookup：固定hit latency返回，且refill请求次数保持不变；
  // 3. 同set不同tag：新line必须覆盖唯一way，旧tag不得继续命中；
  // 4. critical word取line内不同位置：响应在对应beat后出现，line仍到RLAST
  //    才安装完成；
  // 5. 响应反压：hit和early-restart response分别保持若干拍，确认payload稳定；
  // 6. uncached SRAM/MROM：只发一个word请求，不写data/tag array，第二次仍访问下层；
  // 7. 非executable MMIO/空洞：本地返回access fault，不能产生任何refill；
  // 8. refill fault发生在critical之前、当拍和之后：不得安装line，burst必须排空；
  // 9. invalidate在空闲时到达：恰好写ICACHE_SET_COUNT*ICACHE_WAY_COUNT次present=0；
  // 10. invalidate在hit pipeline或miss期间到达：先阻止新lookup，排空旧事务后再清metadata；
  // 11. invalidate后重新访问旧地址：必须重新miss，不能被未清除的tag/data内容误命中；
  // 12. 连续hit吞吐：下游始终ready时，每拍接受请求且按固定顺序返回，身份字段不串线。

endmodule
