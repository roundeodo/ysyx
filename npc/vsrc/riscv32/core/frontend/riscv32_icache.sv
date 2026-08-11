// 两路组相联、阻塞式L1指令缓存顶层，hit路径采用分级流水处理。
//
// 本模块拥有lookup pipeline、way命中选择、替换策略和invalidate协调；tag/data阵列、
// miss跟踪、PMA分类和下层协议转换分别交给子模块。v1目标是hit时每周期接受一个请求、
// 固定两周期lookup延迟，并在INCR refill自然到达关键word时支持early restart。这个边界为
// 后续增加way prediction、多个MSHR、prefetch和更宽fetch保留了独立演进空间。
module riscv32_icache
  import riscv32_pkg::*;
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

  // TODO(ICACHE-TOP-1): 在本TODO正下方声明子模块连线并完成实例化。
  // 可以直接抄写以下完整代码。排列顺序刻意对应一次访问经过的路径：PMA分类、阵列读取、
  // miss处理、阵列写回。AXI4 adapter位于I-cache外部，本模块内部只使用refill语义接口。
  //
  //   pma_attr_t lookup_memory_attr;
  //
  //   logic                        array_read_enable;
  //   icache_set_index_t           array_read_set_index;
  //   icache_word_index_t          array_read_word_index;
  //   icache_tag_t                 array_read_tag_array[ICACHE_WAY_COUNT];
  //   logic [ICACHE_WAY_COUNT-1:0] array_read_line_present_vector;
  //   logic [XLEN-1:0]             array_read_word_data_array[ICACHE_WAY_COUNT];
  //
  //   icache_miss_req_t    miss_req;
  //   logic                miss_req_valid;
  //   logic                miss_req_ready;
  //   icache_lookup_resp_t miss_lookup_resp;
  //   logic                miss_lookup_resp_valid;
  //   logic                miss_lookup_resp_ready;
  //   logic                miss_transaction_present;
  //   icache_event_t       miss_event;
  //
  //   logic                 refill_data_write_valid;
  //   icache_set_index_t    refill_data_write_set_index;
  //   icache_way_index_t    refill_data_write_way_index;
  //   icache_word_index_t   refill_data_write_word_index;
  //   logic [XLEN-1:0]      refill_data_write_word_data;
  //
  //   logic                 refill_metadata_write_valid;
  //   icache_set_index_t    refill_metadata_write_set_index;
  //   icache_way_index_t    refill_metadata_write_way_index;
  //   icache_tag_t          refill_metadata_write_tag;
  //   logic                 refill_metadata_write_line_present;
  //
  //   logic                 metadata_write_valid;
  //   icache_set_index_t    metadata_write_set_index;
  //   icache_way_index_t    metadata_write_way_index;
  //   icache_tag_t          metadata_write_tag;
  //   logic                 metadata_write_line_present;
  //
  //   riscv32_pma u_riscv32_pma (
  //     .lookup_addr_i (lookup_req_i.fetch_addr),
  //     .memory_attr_o (lookup_memory_attr)
  //   );
  //
  //   riscv32_icache_tag_array u_riscv32_icache_tag_array (
  //     .clk_i                         (clk_i),
  //     .rst_ni                        (rst_ni),
  //     .read_enable_i                 (array_read_enable),
  //     .read_set_index_i              (array_read_set_index),
  //     .read_tag_array_o              (array_read_tag_array),
  //     .read_line_present_vector_o    (array_read_line_present_vector),
  //     .metadata_write_valid_i        (metadata_write_valid),
  //     .metadata_write_set_index_i    (metadata_write_set_index),
  //     .metadata_write_way_index_i    (metadata_write_way_index),
  //     .metadata_write_tag_i          (metadata_write_tag),
  //     .metadata_write_line_present_i (metadata_write_line_present)
  //   );
  //
  //   riscv32_icache_data_array u_riscv32_icache_data_array (
  //     .clk_i                     (clk_i),
  //     .read_enable_i             (array_read_enable),
  //     .read_set_index_i          (array_read_set_index),
  //     .read_word_index_i         (array_read_word_index),
  //     .read_word_data_array_o    (array_read_word_data_array),
  //     .refill_write_valid_i      (refill_data_write_valid),
  //     .refill_write_set_index_i  (refill_data_write_set_index),
  //     .refill_write_way_index_i  (refill_data_write_way_index),
  //     .refill_write_word_index_i (refill_data_write_word_index),
  //     .refill_write_word_data_i  (refill_data_write_word_data)
  //   );
  //
  //   riscv32_icache_miss_unit u_riscv32_icache_miss_unit (
  //     .clk_i                         (clk_i),
  //     .rst_ni                        (rst_ni),
  //     .miss_req_i                    (miss_req),
  //     .miss_req_valid_i              (miss_req_valid),
  //     .miss_req_ready_o              (miss_req_ready),
  //     .lookup_resp_o                 (miss_lookup_resp),
  //     .lookup_resp_valid_o           (miss_lookup_resp_valid),
  //     .lookup_resp_ready_i           (miss_lookup_resp_ready),
  //     .refill_req_o                  (refill_req_o),
  //     .refill_req_valid_o            (refill_req_valid_o),
  //     .refill_req_ready_i            (refill_req_ready_i),
  //     .refill_resp_i                 (refill_resp_i),
  //     .refill_resp_valid_i           (refill_resp_valid_i),
  //     .refill_resp_ready_o           (refill_resp_ready_o),
  //     .data_write_valid_o            (refill_data_write_valid),
  //     .data_write_set_index_o        (refill_data_write_set_index),
  //     .data_write_way_index_o        (refill_data_write_way_index),
  //     .data_write_word_index_o       (refill_data_write_word_index),
  //     .data_write_word_data_o        (refill_data_write_word_data),
  //     .metadata_write_valid_o        (refill_metadata_write_valid),
  //     .metadata_write_set_index_o    (refill_metadata_write_set_index),
  //     .metadata_write_way_index_o    (refill_metadata_write_way_index),
  //     .metadata_write_tag_o          (refill_metadata_write_tag),
  //     .metadata_write_line_present_o (refill_metadata_write_line_present),
  //     .miss_transaction_present_o    (miss_transaction_present),
  //     .event_o                       (miss_event)
  //   );
  //
  // `ICACHE_WAY_COUNT==2`不是防御性容错，而是当前replacement算法的明确设计约束。
  //   initial begin
  //     if (ICACHE_WAY_COUNT != 2) begin
  //       $fatal(1, "riscv32_icache currently requires ICACHE_WAY_COUNT == 2");
  //     end
  //   end

  pma_attr_t                                 lookup_memory_attr;

  logic                                      array_read_enable;
  icache_set_index_t                         array_read_set_index;
  icache_word_index_t                        array_read_word_index;
  icache_tag_t                               array_read_tag_array           [ICACHE_WAY_COUNT];
  logic               [ICACHE_WAY_COUNT-1:0] array_read_line_present_vector;
  logic               [            XLEN-1:0] array_read_word_data_array     [ICACHE_WAY_COUNT];

  icache_miss_req_t                          miss_req;
  logic                                      miss_req_valid;
  logic                                      miss_req_ready;
  // TODO(ICACHE-TOP-2): 在本TODO正下方定义lookup流水寄存器和推进控制信号。
  // 可以直接抄写以下完整声明。S0不是寄存器：它表示输入握手和同步array读请求；
  // S1保存请求身份与PMA属性；S2保存请求身份以及与它对齐的tag/data array快照。
  //
  //   icache_lookup_req_t lookup_s1_q, lookup_s1_d;
  //   pma_attr_t          memory_attr_s1_q, memory_attr_s1_d;
  //   logic               lookup_s1_present_q, lookup_s1_present_d;
  //
  //   icache_lookup_req_t lookup_s2_q, lookup_s2_d;
  //   pma_attr_t          memory_attr_s2_q, memory_attr_s2_d;
  //   logic               lookup_s2_present_q, lookup_s2_present_d;
  //
  //   icache_tag_t                 lookup_tag_array_s2_q[ICACHE_WAY_COUNT];
  //   icache_tag_t                 lookup_tag_array_s2_d[ICACHE_WAY_COUNT];
  //   logic [ICACHE_WAY_COUNT-1:0] lookup_line_present_vector_s2_q;
  //   logic [ICACHE_WAY_COUNT-1:0] lookup_line_present_vector_s2_d;
  //   logic [XLEN-1:0]             lookup_word_data_array_s2_q[ICACHE_WAY_COUNT];
  //   logic [XLEN-1:0]             lookup_word_data_array_s2_d[ICACHE_WAY_COUNT];
  //
  //   logic lookup_req_handshake;
  //   logic lookup_s1_ready;
  //   logic lookup_s2_ready;
  //   logic lookup_s2_completed;
  //   logic local_lookup_resp_handshake;
  //   logic miss_req_handshake;
  //
  // present表示流水寄存器中是否保存有效请求，ready表示本拍结束时是否可以覆盖它。
  // miss被miss unit接收的当拍必须清空S2并冻结S1，不能顺手把年轻请求推进S2；否则
  // miss response尚未返回时，年轻请求可能先产生本地hit response，破坏顺序。

  // TODO(ICACHE-TOP-3): 在本TODO正下方实现地址字段提取函数，供S0和S2共同使用。
  // 可以直接抄写以下完整代码：
  //
  //   function automatic icache_set_index_t get_icache_set_index(
  //       input logic [XLEN-1:0] addr);
  //     return addr[ICACHE_LINE_OFFSET_W + ICACHE_SET_INDEX_W - 1
  //                 -: ICACHE_SET_INDEX_W];
  //   endfunction
  //
  //   function automatic icache_word_index_t get_icache_word_index(
  //       input logic [XLEN-1:0] addr);
  //     return addr[ICACHE_LINE_OFFSET_W-1 -: ICACHE_WORD_INDEX_W];
  //   endfunction
  //
  //   function automatic icache_tag_t get_icache_tag(input logic [XLEN-1:0] addr);
  //     return addr[XLEN-1 -: ICACHE_TAG_W];
  //   endfunction
  //
  // 当前参数对应offset[4:0]、set[11:5]、tag[31:12]，word index为[4:2]；上述写法
  // 不依赖这些硬编码位置。还可定义line-base函数，把低ICACHE_LINE_OFFSET_W位清零，
  // 但miss unit已经从原fetch_addr生成line base，顶层不应重复保存第二份地址。
  // 所有输入都是物理地址；本项目当前没有MMU，未来加入翻译后仍应由PMA接收翻译后的地址。

  // TODO(ICACHE-TOP-4): 在本TODO正下方写S2 hit compare、way选择和请求分类逻辑。
  // 可以直接抄写以下完整代码：
  //   logic [ICACHE_WAY_COUNT-1:0] lookup_way_hit_vector;
  //   logic                        lookup_hit;
  //   logic                        hit_way_selected;
  //   icache_way_index_t           lookup_hit_way_index;
  //   logic [XLEN-1:0]             lookup_hit_word_data;
  //   logic                        lookup_access_fault;
  //   logic                        lookup_uncached;
  //   logic                        lookup_cache_miss;
  //   logic                        local_lookup_resp_valid;
  //   icache_lookup_resp_t         local_lookup_resp;
  //
  //   always_comb begin
  //     lookup_way_hit_vector = '0;
  //     lookup_hit            = 1'b0;
  //     hit_way_selected      = 1'b0;
  //     lookup_hit_way_index  = '0;
  //     lookup_hit_word_data  = '0;
  //
  //     for (int unsigned way_index = 0;
  //          way_index < ICACHE_WAY_COUNT;
  //          way_index++) begin
  //       lookup_way_hit_vector[way_index] = lookup_s2_present_q &&
  //           memory_attr_s2_q.executable &&
  //           memory_attr_s2_q.cacheable &&
  //           lookup_line_present_vector_s2_q[way_index] &&
  //           (lookup_tag_array_s2_q[way_index] ==
  //            get_icache_tag(lookup_s2_q.fetch_addr));
  //     end
  //
  //     lookup_hit = |lookup_way_hit_vector;
  //
  //     // 正常情况下只会命中一路。这里编码第一路命中，TOP-8用$onehot0断言
  //     // 检查metadata损坏，不能让优先选择逻辑静默掩盖两路同时命中的错误。
  //     for (int unsigned way_index = 0;
  //          way_index < ICACHE_WAY_COUNT;
  //          way_index++) begin
  //       if (lookup_way_hit_vector[way_index] && !hit_way_selected) begin
  //         lookup_hit_way_index = icache_way_index_t'(way_index);
  //         lookup_hit_word_data = lookup_word_data_array_s2_q[way_index];
  //         hit_way_selected     = 1'b1;
  //       end
  //     end
  //
  //     lookup_access_fault = lookup_s2_present_q &&
  //                           !memory_attr_s2_q.executable;
  //     lookup_uncached     = lookup_s2_present_q &&
  //                           memory_attr_s2_q.executable &&
  //                           !memory_attr_s2_q.cacheable;
  //     lookup_cache_miss   = lookup_s2_present_q &&
  //                           memory_attr_s2_q.executable &&
  //                           memory_attr_s2_q.cacheable &&
  //                           !lookup_hit;
  //
  //     local_lookup_resp_valid = lookup_access_fault || lookup_hit;
  //     local_lookup_resp                 = '0;
  //     local_lookup_resp.fetch_addr      = lookup_s2_q.fetch_addr;
  //     local_lookup_resp.frontend_tag    = lookup_s2_q.frontend_tag;
  //     local_lookup_resp.fetch_epoch     = lookup_s2_q.fetch_epoch;
  //     local_lookup_resp.access_fault    = lookup_access_fault;
  //     local_lookup_resp.fetch_data      = lookup_hit ? lookup_hit_word_data : '0;
  //   end
  //
  // 四类结果互斥：不可执行地址本地返回fault；可执行但不可缓存地址走单word uncached
  // 访问；cacheable地址命中时本地返回，未命中时请求整line refill。响应反压时S2保持，
  // 所以上述组合payload也随S2保持，无需重复增加response寄存器。

  // TODO(ICACHE-TOP-5): 在本TODO正下方实现响应仲裁、miss分派和lookup pipeline。
  // 可以直接抄写以下完整代码。顺序为输出逻辑、握手/ready、next逻辑和分组时序更新。
  //
  //   always_comb begin
  //     lookup_resp_o          = local_lookup_resp;
  //     lookup_resp_valid_o    = local_lookup_resp_valid;
  //     miss_lookup_resp_ready = 1'b0;
  //
  //     // miss response优先。阻塞式结构不允许它与本地响应同时有效，TOP-8会断言。
  //     if (miss_lookup_resp_valid) begin
  //       lookup_resp_o          = miss_lookup_resp;
  //       lookup_resp_valid_o    = 1'b1;
  //       miss_lookup_resp_ready = lookup_resp_ready_i;
  //     end
  //
  //     miss_req                       = '0;
  //     miss_req.lookup_req            = lookup_s2_q;
  //     miss_req.memory_attr           = memory_attr_s2_q;
  //     miss_req.set_index             = get_icache_set_index(lookup_s2_q.fetch_addr);
  //     miss_req.critical_word_index   = get_icache_word_index(lookup_s2_q.fetch_addr);
  //     miss_req.replacement_way_index = replacement_way_index;
  //     miss_req.refill_tag            = get_icache_tag(lookup_s2_q.fetch_addr);
  //     miss_req_valid                 = lookup_s2_present_q &&
  //                                      (lookup_cache_miss || lookup_uncached);
  //
  //     array_read_enable     = lookup_req_handshake;
  //     array_read_set_index  = get_icache_set_index(lookup_req_i.fetch_addr);
  //     array_read_word_index = get_icache_word_index(lookup_req_i.fetch_addr);
  //   end
  //
  //   assign local_lookup_resp_handshake = local_lookup_resp_valid &&
  //                                               lookup_resp_ready_i &&
  //                                               !miss_lookup_resp_valid;
  //   assign miss_req_handshake          = miss_req_valid && miss_req_ready;
  //   assign lookup_s2_completed         = local_lookup_resp_handshake ||
  //                                               miss_req_handshake;
  //   assign lookup_s2_ready             = !lookup_s2_present_q ||
  //                                               lookup_s2_completed;
  //
  //   // miss_req_valid在分派当拍阻止S1推进；miss_transaction_present在后续整个refill
  //   // 期间继续冻结S1。这样年轻请求不会越过正在处理的miss。
  //   assign lookup_s1_ready = (!lookup_s1_present_q || lookup_s2_ready) &&
  //                            !miss_req_valid &&
  //                            !miss_transaction_present;
  //
  //   assign lookup_req_ready_o = lookup_s1_ready &&
  //                               !invalidate_blocks_lookup &&
  //                               !invalidate_req_i;
  //   assign lookup_req_handshake = lookup_req_valid_i && lookup_req_ready_o;
  //
  //   always_comb begin
  //     lookup_s1_d         = lookup_s1_q;
  //     memory_attr_s1_d    = memory_attr_s1_q;
  //     lookup_s1_present_d = lookup_s1_present_q;
  //
  //     lookup_s2_d                         = lookup_s2_q;
  //     memory_attr_s2_d                    = memory_attr_s2_q;
  //     lookup_s2_present_d                 = lookup_s2_present_q;
  //     lookup_line_present_vector_s2_d     = lookup_line_present_vector_s2_q;
  //
  //     for (int unsigned way_index = 0;
  //          way_index < ICACHE_WAY_COUNT;
  //          way_index++) begin
  //       lookup_tag_array_s2_d[way_index]       = lookup_tag_array_s2_q[way_index];
  //       lookup_word_data_array_s2_d[way_index] = lookup_word_data_array_s2_q[way_index];
  //     end
  //
  //     // miss请求身份已转移到miss unit后清空S2，但本拍不能装入年轻S1请求。
  //     if (miss_req_handshake) begin
  //       lookup_s2_present_d = 1'b0;
  //     end else if (lookup_s2_ready && !miss_transaction_present) begin
  //       lookup_s2_present_d = lookup_s1_present_q;
  //       if (lookup_s1_present_q) begin
  //         lookup_s2_d                     = lookup_s1_q;
  //         memory_attr_s2_d                = memory_attr_s1_q;
  //         lookup_line_present_vector_s2_d = array_read_line_present_vector;
  //
  //         for (int unsigned way_index = 0;
  //              way_index < ICACHE_WAY_COUNT;
  //              way_index++) begin
  //           lookup_tag_array_s2_d[way_index]       = array_read_tag_array[way_index];
  //           lookup_word_data_array_s2_d[way_index] = array_read_word_data_array[way_index];
  //         end
  //       end
  //     end
  //
  //     if (lookup_s1_ready) begin
  //       lookup_s1_present_d = lookup_req_handshake;
  //       if (lookup_req_handshake) begin
  //         lookup_s1_d      = lookup_req_i;
  //         memory_attr_s1_d = lookup_memory_attr;
  //       end
  //     end
  //   end
  //
  //   always_ff @(posedge clk_i) begin
  //     if (!rst_ni) begin
  //       lookup_s1_q         <= '0;
  //       memory_attr_s1_q    <= '0;
  //       lookup_s1_present_q <= 1'b0;
  //     end else begin
  //       lookup_s1_q         <= lookup_s1_d;
  //       memory_attr_s1_q    <= memory_attr_s1_d;
  //       lookup_s1_present_q <= lookup_s1_present_d;
  //     end
  //   end
  //
  //   always_ff @(posedge clk_i) begin
  //     if (!rst_ni) begin
  //       lookup_s2_q         <= '0;
  //       memory_attr_s2_q    <= '0;
  //       lookup_s2_present_q <= 1'b0;
  //     end else begin
  //       lookup_s2_q         <= lookup_s2_d;
  //       memory_attr_s2_q    <= memory_attr_s2_d;
  //       lookup_s2_present_q <= lookup_s2_present_d;
  //     end
  //   end
  //
  //   always_ff @(posedge clk_i) begin
  //     if (!rst_ni) begin
  //       lookup_line_present_vector_s2_q <= '0;
  //       for (int unsigned way_index = 0;
  //            way_index < ICACHE_WAY_COUNT;
  //            way_index++) begin
  //         lookup_tag_array_s2_q[way_index]       <= '0;
  //         lookup_word_data_array_s2_q[way_index] <= '0;
  //       end
  //     end else begin
  //       lookup_line_present_vector_s2_q <= lookup_line_present_vector_s2_d;
  //       for (int unsigned way_index = 0;
  //            way_index < ICACHE_WAY_COUNT;
  //            way_index++) begin
  //         lookup_tag_array_s2_q[way_index]       <= lookup_tag_array_s2_d[way_index];
  //         lookup_word_data_array_s2_q[way_index] <= lookup_word_data_array_s2_d[way_index];
  //       end
  //     end
  //   end
  //
  // 无miss且下游ready时，该elastic pipeline可以每拍接收一个lookup。early restart只让
  // critical word提前交付；唯一MSHR在整条line完成前仍占用，所以这里不是hit-under-miss。

  // TODO(ICACHE-TOP-6): 在本TODO正下方实现两路cache的replacement policy。
  // 可以直接抄写以下完整代码：
  //
  //   icache_way_index_t replacement_way_index_array_q[ICACHE_SET_COUNT];
  //   icache_way_index_t replacement_way_index;
  //   logic replacement_state_update_valid;
  //   icache_set_index_t replacement_state_update_set_index;
  //   icache_way_index_t replacement_state_update_accessed_way_index;
  //
  //   always_comb begin
  //     replacement_way_index = replacement_way_index_array_q[
  //         get_icache_set_index(lookup_s2_q.fetch_addr)];
  //
  //     // 无效way优先，避免在仍有空槽时淘汰有效line。
  //     if (!lookup_line_present_vector_s2_q[0]) begin
  //       replacement_way_index = icache_way_index_t'(0);
  //     end else if (!lookup_line_present_vector_s2_q[1]) begin
  //       replacement_way_index = icache_way_index_t'(1);
  //     end
  //   end
  //
  //   always_comb begin
  //     replacement_state_update_valid              = 1'b0;
  //     replacement_state_update_set_index          = '0;
  //     replacement_state_update_accessed_way_index = '0;
  //
  //     // hit被IFU真正消费后，记录本次访问的way。
  //     if (local_lookup_resp_handshake && lookup_hit) begin
  //       replacement_state_update_valid              = 1'b1;
  //       replacement_state_update_set_index          =
  //           get_icache_set_index(lookup_s2_q.fetch_addr);
  //       replacement_state_update_accessed_way_index = lookup_hit_way_index;
  //     end
  //
  //     // refill metadata提交表示新line已经完整安装，也应更新replacement状态。
  //     // 阻塞式设计不会与hit更新同拍发生，TOP-8会断言这一约束。
  //     if (refill_metadata_write_valid) begin
  //       replacement_state_update_valid              = 1'b1;
  //       replacement_state_update_set_index          = refill_metadata_write_set_index;
  //       replacement_state_update_accessed_way_index = refill_metadata_write_way_index;
  //     end
  //   end
  //
  //   always_ff @(posedge clk_i) begin
  //     if (!rst_ni) begin
  //       for (int unsigned set_index = 0;
  //            set_index < ICACHE_SET_COUNT;
  //            set_index++) begin
  //         replacement_way_index_array_q[set_index] <= '0;
  //       end
  //     end else if (replacement_state_update_valid) begin
  //       replacement_way_index_array_q[replacement_state_update_set_index] <=
  //           replacement_state_update_accessed_way_index ^ icache_way_index_t'(1);
  //     end
  //   end
  //
  // 每个set保存“两个way均有效时，下次优先替换哪一路”。invalidate无需清该状态，因为
  // victim选择首先检查present。异或1只适用于两路；扩展到4路时必须改成tree-PLRU或
  // 其他明确算法，不能把表面参数化误当成算法已经支持任意way数量。

  // TODO(ICACHE-TOP-7): 在本TODO正下方实现fence.i/invalidate三段式状态机。
  // 可以直接抄写以下完整代码。invalidate_req_i没有ready，因此IDLE必须在看到脉冲后
  // 记住请求；DRAIN先排空旧lookup和miss，CLEAR再逐set、逐way清除present。
  //
  //   typedef enum logic [1:0] {
  //     INVALIDATE_IDLE,
  //     INVALIDATE_DRAIN_LOOKUPS,
  //     INVALIDATE_CLEAR_METADATA,
  //     INVALIDATE_COMPLETE
  //   } invalidate_state_e;
  //
  //   invalidate_state_e  invalidate_state_q, invalidate_state_d;
  //   icache_set_index_t  invalidate_set_index_q, invalidate_set_index_d;
  //   icache_way_index_t  invalidate_way_index_q, invalidate_way_index_d;
  //   logic               invalidate_blocks_lookup;
  //   logic               invalidate_metadata_write_valid;
  //
  //   // 第一段：只根据当前状态产生输出。CLEAR的每一个周期恰好清除一个metadata项。
  //   always_comb begin
  //     invalidate_blocks_lookup        = (invalidate_state_q != INVALIDATE_IDLE);
  //     invalidate_done_o               = 1'b0;
  //     invalidate_metadata_write_valid = 1'b0;
  //
  //     unique case (invalidate_state_q)
  //       INVALIDATE_CLEAR_METADATA: begin
  //         invalidate_metadata_write_valid = 1'b1;
  //       end
  //
  //       INVALIDATE_COMPLETE: begin
  //         invalidate_done_o = 1'b1;
  //       end
  //
  //       default: ;
  //     endcase
  //   end
  //
  //   // 第二段：计算下一状态和清除地址。最后一个way完成后再推进set。
  //   always_comb begin
  //     invalidate_state_d     = invalidate_state_q;
  //     invalidate_set_index_d = invalidate_set_index_q;
  //     invalidate_way_index_d = invalidate_way_index_q;
  //
  //     unique case (invalidate_state_q)
  //       INVALIDATE_IDLE: begin
  //         if (invalidate_req_i) begin
  //           invalidate_state_d = INVALIDATE_DRAIN_LOOKUPS;
  //         end
  //       end
  //
  //       INVALIDATE_DRAIN_LOOKUPS: begin
  //         if (!lookup_s1_present_q &&
  //             !lookup_s2_present_q &&
  //             !miss_transaction_present) begin
  //           invalidate_set_index_d = '0;
  //           invalidate_way_index_d = '0;
  //           invalidate_state_d     = INVALIDATE_CLEAR_METADATA;
  //         end
  //       end
  //
  //       INVALIDATE_CLEAR_METADATA: begin
  //         if (invalidate_way_index_q ==
  //             icache_way_index_t'(ICACHE_WAY_COUNT - 1)) begin
  //           invalidate_way_index_d = '0;
  //
  //           if (invalidate_set_index_q ==
  //               icache_set_index_t'(ICACHE_SET_COUNT - 1)) begin
  //             invalidate_state_d = INVALIDATE_COMPLETE;
  //           end else begin
  //             invalidate_set_index_d = invalidate_set_index_q +
  //                                      icache_set_index_t'(1);
  //           end
  //         end else begin
  //           invalidate_way_index_d = invalidate_way_index_q +
  //                                    icache_way_index_t'(1);
  //         end
  //       end
  //
  //       INVALIDATE_COMPLETE: begin
  //         invalidate_state_d = INVALIDATE_IDLE;
  //       end
  //
  //       default: begin
  //         invalidate_state_d     = INVALIDATE_IDLE;
  //         invalidate_set_index_d = '0;
  //         invalidate_way_index_d = '0;
  //       end
  //     endcase
  //   end
  //
  //   // 第三段：状态寄存器和遍历计数器分组更新，便于定位各寄存器的归属。
  //   always_ff @(posedge clk_i) begin
  //     if (!rst_ni) begin
  //       invalidate_state_q <= INVALIDATE_IDLE;
  //     end else begin
  //       invalidate_state_q <= invalidate_state_d;
  //     end
  //   end
  //
  //   always_ff @(posedge clk_i) begin
  //     if (!rst_ni) begin
  //       invalidate_set_index_q <= '0;
  //       invalidate_way_index_q <= '0;
  //     end else begin
  //       invalidate_set_index_q <= invalidate_set_index_d;
  //       invalidate_way_index_q <= invalidate_way_index_d;
  //     end
  //   end
  //
  //   // tag array只有一个metadata写口。正常refill直接转发；invalidate清除操作优先。
  //   // CLEAR只会在miss排空后开始，因此两种写入按设计不应真正发生冲突。
  //   always_comb begin
  //     metadata_write_valid        = refill_metadata_write_valid;
  //     metadata_write_set_index    = refill_metadata_write_set_index;
  //     metadata_write_way_index    = refill_metadata_write_way_index;
  //     metadata_write_tag          = refill_metadata_write_tag;
  //     metadata_write_line_present = refill_metadata_write_line_present;
  //
  //     if (invalidate_metadata_write_valid) begin
  //       metadata_write_valid        = 1'b1;
  //       metadata_write_set_index    = invalidate_set_index_q;
  //       metadata_write_way_index    = invalidate_way_index_q;
  //       metadata_write_tag          = '0;
  //       metadata_write_line_present = 1'b0;
  //     end
  //   end
  //
  //   assign cache_busy_o = lookup_s1_present_q ||
  //                         lookup_s2_present_q ||
  //                         miss_transaction_present ||
  //                         invalidate_req_i ||
  //                         (invalidate_state_q != INVALIDATE_IDLE);
  //
  // invalidate只清present，不清tag/data，因为present=0已经使旧内容在架构上不可见。
  // 已经发出的下层事务必须完整握手，不能因fence.i中途撤销。当前接口要求
  // invalidate_req_i为单周期脉冲；若未来允许电平请求，应另加等待请求撤销状态。
  // 当前单核无DMA一致性，fence.i用于保证软件修改代码后不再取到旧指令line。

  // TODO(ICACHE-TOP-8): 在本TODO正下方合并event_o并添加协议断言。
  // 可以直接抄写以下完整代码。event是观测信号，必须绑定一次真正发生的握手，不能反向
  // 参与cache控制，也不能在valid因反压保持多拍时重复计数。
  //
  //   always_comb begin
  //     event_o                                         = '0;
  //     event_o.lookup_occurred                         = lookup_req_handshake;
  //     event_o.hit_occurred                            =
  //         local_lookup_resp_handshake && lookup_hit;
  //     event_o.miss_occurred                           = miss_event.miss_occurred;
  //     event_o.uncached_access_occurred                =
  //         miss_req_handshake && lookup_uncached;
  //     event_o.refill_word_occurred                    =
  //         miss_event.refill_word_occurred;
  //     event_o.refill_line_completed_occurred          =
  //         miss_event.refill_line_completed_occurred;
  //     event_o.stale_response_discarded_occurred       = 1'b0;
  //   end
  //
  // `ifndef SYNTHESIS
  //   property p_lookup_request_stable_while_stalled;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       lookup_req_valid_i && !lookup_req_ready_o
  //       |=> lookup_req_valid_i && $stable(lookup_req_i);
  //   endproperty
  //
  //   property p_lookup_response_stable_while_stalled;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       lookup_resp_valid_o && !lookup_resp_ready_i
  //       |=> lookup_resp_valid_o && $stable(lookup_resp_o);
  //   endproperty
  //
  //   property p_hit_vector_is_onehot_or_zero;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       $onehot0(lookup_way_hit_vector);
  //   endproperty
  //
  //   property p_local_and_miss_response_are_exclusive;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       !(local_lookup_resp_valid && miss_lookup_resp_valid);
  //   endproperty
  //
  //   property p_miss_request_has_valid_classification;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       miss_req_valid |->
  //       lookup_s2_present_q && (lookup_cache_miss || lookup_uncached);
  //   endproperty
  //
  //   property p_array_read_matches_lookup_acceptance;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       array_read_enable == lookup_req_handshake;
  //   endproperty
  //
  //   property p_metadata_write_sources_are_exclusive;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       !(refill_metadata_write_valid && invalidate_metadata_write_valid);
  //   endproperty
  //
  //   property p_invalidate_clear_blocks_lookup;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       invalidate_state_q == INVALIDATE_CLEAR_METADATA
  //       |-> !lookup_req_ready_o;
  //   endproperty
  //
  //   property p_present_install_comes_from_refill;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       metadata_write_valid && metadata_write_line_present
  //       |-> refill_metadata_write_valid;
  //   endproperty
  //
  //   property p_present_clear_comes_from_invalidate;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       metadata_write_valid && !metadata_write_line_present
  //       |-> invalidate_metadata_write_valid;
  //   endproperty
  //
  //   property p_blocking_miss_stops_new_lookup;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       miss_transaction_present |-> !lookup_req_handshake;
  //   endproperty
  //
  //   property p_miss_dispatch_freezes_s1;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       miss_req_valid |-> !lookup_s1_ready;
  //   endproperty
  //
  //   property p_replacement_updates_are_exclusive;
  //     @(posedge clk_i) disable iff (!rst_ni)
  //       !(local_lookup_resp_handshake && lookup_hit &&
  //         refill_metadata_write_valid);
  //   endproperty
  //
  //   assert property (p_lookup_request_stable_while_stalled)
  //     else $error("I-cache lookup request changed while stalled");
  //   assert property (p_lookup_response_stable_while_stalled)
  //     else $error("I-cache lookup response changed while stalled");
  //   assert property (p_hit_vector_is_onehot_or_zero)
  //     else $error("I-cache lookup matched more than one way");
  //   assert property (p_local_and_miss_response_are_exclusive)
  //     else $error("I-cache local and miss responses are both valid");
  //   assert property (p_miss_request_has_valid_classification)
  //     else $error("I-cache miss request has no valid S2 classification");
  //   assert property (p_array_read_matches_lookup_acceptance)
  //     else $error("I-cache array read does not match lookup handshake");
  //   assert property (p_metadata_write_sources_are_exclusive)
  //     else $error("I-cache refill and invalidate metadata writes conflict");
  //   assert property (p_invalidate_clear_blocks_lookup)
  //     else $error("I-cache accepted lookup while clearing metadata");
  //   assert property (p_present_install_comes_from_refill)
  //     else $error("I-cache present bit installation did not come from refill");
  //   assert property (p_present_clear_comes_from_invalidate)
  //     else $error("I-cache present bit clear did not come from invalidate");
  //   assert property (p_blocking_miss_stops_new_lookup)
  //     else $error("Blocking I-cache accepted lookup during active miss");
  //   assert property (p_miss_dispatch_freezes_s1)
  //     else $error("I-cache S1 advanced while dispatching a miss");
  //   assert property (p_replacement_updates_are_exclusive)
  //     else $error("I-cache replacement state has two update sources");
  // `endif
  //
  // stale_response_discarded_occurred保持0，因为fetch epoch是否过期由IFU判断。access
  // fault目前没有独立event字段，所以包含fault时不能使用
  // `lookup == hit + miss + uncached`；需要该恒等式时应在pkg新增access-fault事件。

  // TODO(ICACHE-TOP-9): 完成后按以下顺序编写directed tests。每项都检查握手次数、
  // payload身份、array写次数和event脉冲，不能只比较最终instruction：
  // 1. 冷启动cacheable miss：8个word逐拍返回，确认8次data写、1次metadata提交；
  // 2. 同地址再次lookup：固定hit latency返回，且refill请求次数保持不变；
  // 3. 同set不同tag：先填满两路，再访问第三条line，确认invalid-way优先和两路替换状态；
  // 4. critical word为0、3、7：响应分别在对应beat后出现，line仍到RLAST才安装完成；
  // 5. 响应反压：hit和early-restart response分别保持若干拍，确认payload稳定；
  // 6. uncached SRAM/MROM：只发一个word请求，不写data/tag array，第二次仍访问下层；
  // 7. 非executable MMIO/空洞：本地返回access fault，不能产生任何refill；
  // 8. refill fault发生在critical之前、当拍和之后：不得安装line，burst必须排空；
  // 9. invalidate在空闲时到达：恰好写ICACHE_SET_COUNT*ICACHE_WAY_COUNT次present=0；
  // 10. invalidate在hit pipeline或miss期间到达：先阻止新lookup，排空旧事务后再清metadata；
  // 11. invalidate后重新访问旧地址：必须重新miss，不能被未清除的tag/data内容误命中；
  // 12. 连续hit吞吐：下游始终ready时，每拍接受请求且按固定顺序返回，身份字段不串线。

endmodule
