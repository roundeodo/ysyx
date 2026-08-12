// 阻塞式I-cache miss跟踪与line安装单元，v1只包含一个MSHR等价表项。
//
// 本模块保存一次miss从分配到完整refill结束所需的全部状态，包括原取指身份、
// victim位置、返回word集合和错误状态。标准INCR burst到达critical word时允许先返回
// 给前端，但只有全部word成功写入后才提交metadata。v1在refill期间阻塞新lookup，因此
// early restart不是hit-under-miss；未来增加多个MSHR时，应扩展表项和事务匹配，而不是
// 改变IFU接口。
module riscv32_icache_miss_unit
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    // Lookup在tag比较确认miss后，通过本通道分配唯一的MSHR表项。
    // ready只在IDLE拉高，因此该版本同一时刻最多跟踪一个miss。
    input  icache_miss_req_t miss_req_i,
    input  logic             miss_req_valid_i,
    output logic             miss_req_ready_o,

    // Miss unit通过本通道把critical word及原取指身份返回给Lookup/IFU。
    // valid被反压时，整个lookup_resp_o必须保持不变。
    output icache_lookup_resp_t lookup_resp_o,
    output logic                lookup_resp_valid_o,
    input  logic                lookup_resp_ready_i,

    // 面向下级存储层的refill通道。请求描述cache line和critical word；响应每拍
    // 返回一个word，并用last_word标记整个事务结束。
    output icache_refill_req_t             refill_req_o,
    output logic                           refill_req_valid_o,
    input  logic                           refill_req_ready_i,
    input  icache_refill_resp_t            refill_resp_i,
    input  logic                           refill_resp_valid_i,
    output logic                           refill_resp_ready_o,
    // Data array逐word写口。每个无错误的cacheable响应beat握手时写入一次，
    // 不必等整条cache line全部返回后再集中写入。
    output logic                           data_write_valid_o,
    output icache_set_index_t              data_write_set_index_o,
    output icache_way_index_t              data_write_way_index_o,
    output icache_word_index_t             data_write_word_index_o,
    output logic                [XLEN-1:0] data_write_word_data_o,

    // Tag array元数据写口，同一个接口承担两种操作：
    // 1. 发出refill请求时写line_present=0，先使victim失效；
    // 2. 最后一个word完整且无错误时写line_present=1，正式安装新cache line。
    output logic              metadata_write_valid_o,
    output icache_set_index_t metadata_write_set_index_o,
    output icache_way_index_t metadata_write_way_index_o,
    output icache_tag_t       metadata_write_tag_o,
    output logic              metadata_write_line_present_o,

    // 占用状态供I-cache顶层阻塞新lookup；事件脉冲供PMU统计miss和refill行为。
    output logic          miss_transaction_present_o,
    output icache_event_t event_o
);

  // 单MSHR的状态、上下文寄存器和握手派生信号。
  // 四个状态的职责必须保持单一：
  // - IDLE：没有MSHR内容，只能在这里接受miss_req；
  // - SEND_REFILL_REQUEST：miss_req_q已稳定，等待下层接收一次refill请求；
  // - RECEIVE_REFILL：逐beat接收响应、写data array，并尽早产生lookup response；
  // - COMPLETE：下层事务已经结束，只等待缓存的lookup response被IFU接收。
  //
  // `lookup_resp_present_q`表示响应寄存器中保存着尚未消费的内容；
  // `lookup_response_generated_q`表示本次miss已经生成过唯一一次lookup response，即使
  // early-restart响应已被IFU消费，该位也必须保持1直到整个refill结束。不能只使用
  // lookup_resp_present_q记录这个历史，否则响应被消费后，后续beat可能错误地产生第二
  // 个响应。
  // `refill_access_fault_seen_q`表示本次burst此前任一beat返回过错误。两者都不是状态机
  // 的替代品。第一版只有一个MSHR，transaction_index固定使用0，但请求和响应仍必须
  // 原样携带该字段，为后续多MSHR扩展保留事务匹配边界。
  typedef enum logic [1:0] {
    MISS_IDLE,
    MISS_SEND_REFILL_REQUEST,
    MISS_RECEIVE_REFILL,
    MISS_COMPLETE
  } miss_state_e;

  // 状态寄存器只表示当前事务所处阶段，不保存请求内容。
  miss_state_e state_q, state_d;

  // 单个MSHR的事务上下文：保存原始取指身份、目标set、victim way、tag和PMA属性。
  // 从接受miss开始一直保持到lookup response被IFU消费，保证下游反压不会改变身份。
  icache_miss_req_t miss_req_q, miss_req_d;

  // 每一位对应cache line中的一个word。响应beat握手后置位，用于检查整条line
  // 是否完整返回以及捕获重复word；它不决定AXI事务何时结束，结束仍以last_word为准。
  logic [ICACHE_WORDS_PER_LINE-1:0] received_word_present_vector_q;
  logic [ICACHE_WORDS_PER_LINE-1:0] received_word_present_vector_d;

  // sticky错误位：本次refill任意一个已接收beat报错后保持为1，直到MSHR释放。
  // 这样后续正常beat也不能错误地把一条曾经出错的line安装为有效。
  logic refill_access_fault_seen_q, refill_access_fault_seen_d;

  // 单entry响应缓冲。present表示当前缓冲里有待IFU消费的响应；generated表示
  // 本次miss历史上已经生成过响应，用来保证early restart之后不会重复响应。
  icache_lookup_resp_t lookup_resp_q, lookup_resp_d;
  logic lookup_resp_present_q, lookup_resp_present_d;
  logic lookup_response_generated_q, lookup_response_generated_d;

  // 以下信号只描述当前周期发生的事件，不保存跨周期状态。
  logic miss_req_handshake;
  logic refill_req_handshake;
  logic refill_resp_handshake;
  logic lookup_resp_handshake;
  logic current_refill_word_is_critical;
  logic [ICACHE_WORDS_PER_LINE-1:0] received_word_present_vector_after_current_resp;
  logic all_requested_words_received_after_current_resp;

  // 第一段组合逻辑：只根据当前状态驱动输出，不更新_q寄存器。
  // line base必须通过清零fetch_addr低ICACHE_LINE_OFFSET_W位得到，不要减法或硬编码
  // `5'b0`。lookup响应不只在COMPLETE状态输出：critical word可能在RECEIVE状态提前到达，
  // 所以valid应始终直接由lookup_resp_present_q驱动，直至IFU握手。
  //
  // refill_resp_ready_o在RECEIVE中可以恒为1。一个miss只产生一个lookup response；响应
  // buffer满以后，后续非critical beat仍应继续被接收并排空AXI burst，不能因IFU反压
  // 卡住line refill。每个beat只在refill_resp_handshake当拍写一次data array。
  //
  // refill请求被下层接收时先清除victim present。否则后续beat已经逐拍覆盖data array，
  // 而总线错误又阻止新metadata安装时，旧tag仍可能命中到被部分覆盖的数据。
  // 最后一个成功data word和metadata可以在同一个上升沿写入：该沿之前present仍为0，
  // 该沿之后最后一个word和present同时生效，因此不存在部分line被lookup命中的窗口。
  // 第一版early restart只提前交付critical word；miss unit仍占用唯一MSHR，直到整条line
  // 安装完成。因此它能重叠“关键指令后端执行”和“剩余line refill”，但不能在miss期间
  // 接收另一个lookup，也不能提供hit-under-miss。critical word成功交付后，后续beat若报错，
  // 已交付的目标指令不需要撤销，但错误累计位会阻止整条line安装；本模块也不会生成第二个
  // lookup response。
  always_comb begin
    miss_req_ready_o              = 1'b0;
    lookup_resp_o                 = lookup_resp_q;
    lookup_resp_valid_o           = lookup_resp_present_q;
    refill_req_o                  = '0;
    refill_req_valid_o            = 1'b0;
    refill_resp_ready_o           = 1'b0;
    data_write_valid_o            = 1'b0;
    data_write_set_index_o        = miss_req_q.set_index;
    data_write_way_index_o        = miss_req_q.replacement_way_index;
    data_write_word_index_o       = refill_resp_i.word_index;
    data_write_word_data_o        = refill_resp_i.word_data;
    metadata_write_valid_o        = 1'b0;
    metadata_write_set_index_o    = miss_req_q.set_index;
    metadata_write_way_index_o    = miss_req_q.replacement_way_index;
    metadata_write_tag_o          = miss_req_q.refill_tag;
    metadata_write_line_present_o = 1'b0;
    miss_transaction_present_o    = (state_q != MISS_IDLE);

    unique case (state_q)
      // 空闲时只开放miss分配口；其他输出保持默认无效。
      MISS_IDLE: miss_req_ready_o = 1'b1;

      // 将已锁存的MSHR上下文转换为下级refill请求。valid必须一直保持，直到
      // refill_req_ready_i使握手发生；同一握手周期先使cacheable victim失效。
      MISS_SEND_REFILL_REQUEST: begin
        refill_req_valid_o = 1'b1;
        // 清零块内偏移，得到cache line起始地址。
        refill_req_o.line_base_addr = {
          miss_req_q.lookup_req.fetch_addr[XLEN-1:ICACHE_LINE_OFFSET_W],
          {ICACHE_LINE_OFFSET_W{1'b0}}
        };
        refill_req_o.critical_word_index = miss_req_q.critical_word_index;
        // Cacheable访问取回整条line；uncached访问只取当前word。
        refill_req_o.requested_word_count = miss_req_q.memory_attr.cacheable ? icache_refill_word_count_t'(ICACHE_WORDS_PER_LINE) : icache_refill_word_count_t'(1);
        refill_req_o.transaction_index = '0;

        // 下层正式接收refill请求时立即使victim失效，之后才能安全地逐word覆盖data array。
        metadata_write_valid_o = refill_req_handshake && miss_req_q.memory_attr.cacheable;
        metadata_write_line_present_o = 1'b0;
      end

      // 下级每返回一个beat就立即接收。cacheable且无错误的word直接写data array；
      // 只有last_word到达、所有word齐全且整个事务无错误时才把metadata置为有效。
      MISS_RECEIVE_REFILL: begin
        refill_resp_ready_o = 1'b1;
        data_write_valid_o  = refill_resp_handshake && miss_req_q.memory_attr.cacheable && !refill_access_fault_seen_q && !refill_resp_i.access_fault;

        metadata_write_valid_o        = refill_resp_handshake && refill_resp_i.last_word && miss_req_q.memory_attr.cacheable && !refill_access_fault_seen_q && !refill_resp_i.access_fault && all_requested_words_received_after_current_resp;
        metadata_write_line_present_o = metadata_write_valid_o;
      end

      // 总线事务已经结束，输出由lookup response缓冲寄存器维持；此状态不再访问下级。
      MISS_COMPLETE: ;
      default:       ;
    endcase
  end

  // 第二段组合逻辑：计算状态和数据寄存器的下一值。early restart真正发生在
  // MISS_RECEIVE_REFILL中：critical word握手后立即写入lookup response寄存器，不等待
  // last_word；下一拍lookup_resp_valid_o即可拉高，而状态仍停留在RECEIVE继续接收剩余
  // beat。
  // `all_requested_words_received_after_current_resp`使用“当前握手beat已经置位”的临时
  // vector计算，但状态结束必须以
  // refill_resp_i.last_word握手为准，因为下层AXI4 adapter拥有burst边界。received vector
  // 用于断言和完整性检查，不能代替RLAST。uncached请求只请求一个word，也必须走相同
  // 状态路径，但绝不产生data或metadata array写入。
  always_comb begin
    // 默认保持所有寄存器。每个状态只覆盖自己负责改变的字段，避免遗漏路径产生锁存器。
    state_d                        = state_q;
    miss_req_d                     = miss_req_q;
    received_word_present_vector_d = received_word_present_vector_q;
    refill_access_fault_seen_d     = refill_access_fault_seen_q;
    lookup_resp_d                  = lookup_resp_q;
    lookup_resp_present_d          = lookup_resp_present_q;
    lookup_response_generated_d    = lookup_response_generated_q;

    // IFU接收响应只清空响应缓冲，不立即释放MSHR。若剩余line尚未refill完成，状态机
    // 仍留在RECEIVE；这正是critical-word-first能与后续beat传输重叠的基础。
    if (lookup_resp_handshake) begin
      lookup_resp_present_d = 1'b0;
    end

    unique case (state_q)
      MISS_IDLE: begin
        // 分配MSHR：一次性锁存请求身份，并清空上一事务的进度、错误和响应历史。
        if (miss_req_handshake) begin
          miss_req_d                     = miss_req_i;
          received_word_present_vector_d = '0;
          refill_access_fault_seen_d     = 1'b0;
          lookup_resp_d                  = '0;
          lookup_resp_present_d          = 1'b0;
          lookup_response_generated_d    = 1'b0;
          state_d                        = MISS_SEND_REFILL_REQUEST;
        end
      end

      MISS_SEND_REFILL_REQUEST: begin
        // 请求握手后，下级已经取得稳定payload，后续只需等待逐word响应。
        if (refill_req_handshake) begin
          state_d = MISS_RECEIVE_REFILL;
        end
      end

      MISS_RECEIVE_REFILL: begin
        if (refill_resp_handshake) begin
          // 当前beat已由本模块接收：记录word位置，并把错误永久累计到本次事务。
          received_word_present_vector_d[refill_resp_i.word_index] = 1'b1;
          refill_access_fault_seen_d = refill_access_fault_seen_q || refill_resp_i.access_fault;

          // critical word握手后立即生成唯一一次lookup response，不等待整条line完成。
          if (!lookup_response_generated_q && current_refill_word_is_critical) begin
            lookup_resp_d.fetch_addr = miss_req_q.lookup_req.fetch_addr;
            lookup_resp_d.frontend_tag = miss_req_q.lookup_req.frontend_tag;
            lookup_resp_d.fetch_epoch = miss_req_q.lookup_req.fetch_epoch;
            lookup_resp_d.access_fault = refill_access_fault_seen_q || refill_resp_i.access_fault;
            lookup_resp_d.fetch_data    = (refill_access_fault_seen_q || refill_resp_i.access_fault) ? '0 : refill_resp_i.word_data;
            lookup_resp_present_d = 1'b1;
            lookup_response_generated_d = 1'b1;
          end

          // last_word前未出现critical word表示下层违反refill协议，用fault响应释放MSHR。
          if (refill_resp_i.last_word && !lookup_response_generated_q && !current_refill_word_is_critical) begin
            lookup_resp_d.fetch_addr    = miss_req_q.lookup_req.fetch_addr;
            lookup_resp_d.fetch_data    = '0;
            lookup_resp_d.frontend_tag  = miss_req_q.lookup_req.frontend_tag;
            lookup_resp_d.fetch_epoch   = miss_req_q.lookup_req.fetch_epoch;
            lookup_resp_d.access_fault  = 1'b1;
            lookup_resp_present_d       = 1'b1;
            lookup_response_generated_d = 1'b1;
          end

          // last_word结束下级事务，但不代表IFU一定已经接收响应；因此先进入COMPLETE，
          // 再由响应缓冲的present状态决定何时真正释放MSHR。
          if (refill_resp_i.last_word) begin
            state_d = MISS_COMPLETE;
          end
        end
      end

      MISS_COMPLETE: begin
        // Refill已经结束；等待缓存的lookup response被IFU消费后才能释放唯一MSHR。
        if (!lookup_resp_present_d) begin
          miss_req_d                     = '0;
          received_word_present_vector_d = '0;
          refill_access_fault_seen_d     = 1'b0;
          lookup_resp_d                  = '0;
          lookup_response_generated_d    = 1'b0;
          state_d                        = MISS_IDLE;
        end
      end

      default: begin
        // 非法状态恢复为完全空闲，避免残留valid或旧事务上下文继续驱动接口。
        state_d                        = MISS_IDLE;
        miss_req_d                     = '0;
        received_word_present_vector_d = '0;
        refill_access_fault_seen_d     = '0;
        lookup_resp_d                  = '0;
        lookup_resp_present_d          = 1'b0;
        lookup_response_generated_d    = 1'b0;
      end
    endcase
  end
  // 第三段时序逻辑：状态、MSHR上下文和响应寄存器按职责分组更新，避免一个巨大
  // always_ff混合彼此独立的硬件状态。

  // 状态寄存器：只负责事务阶段推进。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= MISS_IDLE;
    else state_q <= state_d;
  end

  // MSHR上下文与refill进度寄存器：保存“正在为哪次取指填哪条line”。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      miss_req_q                     <= '0;
      received_word_present_vector_q <= '0;
      refill_access_fault_seen_q     <= 1'b0;
    end else begin
      miss_req_q                     <= miss_req_d;
      received_word_present_vector_q <= received_word_present_vector_d;
      refill_access_fault_seen_q     <= refill_access_fault_seen_d;
    end
  end

  // Lookup响应寄存器：把下级返回时序与IFU接收时序解耦，并承受IFU反压。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lookup_resp_q               <= '0;
      lookup_resp_present_q       <= 1'b0;
      lookup_response_generated_q <= 1'b0;
    end else begin
      lookup_resp_q               <= lookup_resp_d;
      lookup_resp_present_q       <= lookup_resp_present_d;
      lookup_response_generated_q <= lookup_response_generated_d;
    end
  end


  // valid和ready同时为1才表示一次传输真正发生。所有状态推进、计数和array写入都以
  // 对应handshake为条件，不能只看valid或ready其中之一。

  assign miss_req_handshake = miss_req_valid_i && miss_req_ready_o;
  assign refill_req_handshake = refill_req_valid_o && refill_req_ready_i;
  assign refill_resp_handshake = refill_resp_valid_i && refill_resp_ready_o;
  assign lookup_resp_handshake = lookup_resp_valid_o && lookup_resp_ready_i;
  assign current_refill_word_is_critical = refill_resp_i.word_index == miss_req_q.critical_word_index;

  // 把当前响应beat临时并入received vector。因为_q只能在上升沿后更新，最后一个beat
  // 到达的当前周期若直接检查_q，会漏掉当前word并错误判断line不完整。
  always_comb begin
    received_word_present_vector_after_current_resp = received_word_present_vector_q;

    if (refill_resp_handshake) begin
      received_word_present_vector_after_current_resp[refill_resp_i.word_index] = 1'b1;
    end
    all_requested_words_received_after_current_resp = &received_word_present_vector_after_current_resp;
  end

  // PMU事件均为单周期脉冲：miss按请求分配计数，refill word按响应握手计数，
  // refill line只按metadata从无效变为有效的安装操作计数，不把victim失效算作完成。
  always_comb begin
    event_o = '0;
    event_o.miss_occurred = miss_req_handshake && miss_req_i.memory_attr.cacheable;
    event_o.refill_word_occurred = refill_resp_handshake && miss_req_q.memory_attr.cacheable;
    event_o.refill_line_completed_occurred = metadata_write_valid_o && metadata_write_line_present_o;
  end
  // 完整line要求临时vector所有位均为1；uncached只请求一个word，不使用这个信号提交
  // metadata。它不能替代last_word，因为事务边界由下层adapter根据AXI4 RLAST确定。
`ifndef SYNTHESIS
  // 占用和状态约束：单MSHR忙时不得接受第二个miss，refill响应只能在接收状态消费。
  a_miss_request_only_accepted_when_idle :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (state_q != MISS_IDLE) |-> !miss_req_ready_o
  )
  else $error("I-cache miss unit accepted a second miss while its MSHR was occupied");

  a_refill_response_only_accepted_in_receive_state :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      refill_resp_handshake |-> (state_q == MISS_RECEIVE_REFILL)
  )
  else $error("I-cache miss unit accepted a refill response in an invalid state");

  // Ready/valid稳定性约束：发送方在valid=1且ready=0时必须保持valid和payload稳定。
  a_refill_request_stable_while_stalled :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (refill_req_valid_o && !refill_req_ready_i) |=>
          (refill_req_valid_o && $stable(
      refill_req_o
  )))
  else $error("I-cache refill request changed while stalled");

  a_lookup_response_stable_while_stalled :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (lookup_resp_valid_o && !lookup_resp_ready_i) |=>
          (lookup_resp_valid_o && $stable(
      lookup_resp_o
  )))
  else $error("I-cache lookup response changed while stalled");

  // 事务身份和beat完整性约束：当前版本只接受transaction 0，并禁止同一word重复返回。
  a_refill_response_matches_single_mshr :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (refill_resp_valid_i && state_q == MISS_RECEIVE_REFILL) |->
          (refill_resp_i.transaction_index == '0)
  )
  else $error("I-cache refill response does not belong to the active MSHR");

  a_cacheable_refill_word_received_once :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (refill_resp_handshake && miss_req_q.memory_attr.cacheable) |->
          !received_word_present_vector_q[refill_resp_i.word_index]
  )
  else $error("I-cache refill returned the same cache-line word more than once");

  // Cache line安装约束：先失效victim，再逐word覆盖；只有完整且无错误的line才能
  // 重新写present=1。下面几条断言共同保护这一提交顺序。
  a_metadata_commit_requires_complete_error_free_line :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (metadata_write_valid_o && metadata_write_line_present_o) |->
          (data_write_valid_o && refill_resp_i.last_word &&
           all_requested_words_received_after_current_resp &&
           !refill_access_fault_seen_q && !refill_resp_i.access_fault)
  )
  else $error("I-cache metadata was committed before a complete error-free line arrived");

  // Cacheable refill一旦被下层接收，victim metadata必须先失效。之后即使burst报错，
  // 已被部分覆盖的data way也不会以旧tag重新命中。
  a_cacheable_refill_invalidates_victim_before_data_overwrite :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (refill_req_handshake && miss_req_q.memory_attr.cacheable) |->
          (metadata_write_valid_o && !metadata_write_line_present_o)
  )
  else $error("I-cache refill did not invalidate its victim before data overwrite");

  a_successful_last_beat_completes_cacheable_line :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (refill_resp_handshake && refill_resp_i.last_word &&
       miss_req_q.memory_attr.cacheable &&
       !refill_access_fault_seen_q && !refill_resp_i.access_fault) |->
          all_requested_words_received_after_current_resp
  )
  else $error("I-cache refill ended before every requested word arrived");

  a_uncached_request_never_writes_cache_arrays :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (!miss_req_q.memory_attr.cacheable && state_q != MISS_IDLE) |->
          (!data_write_valid_o && !metadata_write_valid_o)
  )
  else $error("I-cache array write occurred for an uncached fetch");

  a_faulted_refill_never_installs_line :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      (refill_access_fault_seen_q ||
       (refill_resp_handshake && refill_resp_i.access_fault)) |->
          !(metadata_write_valid_o && metadata_write_line_present_o)
  )
  else $error("I-cache installed a line from a faulted refill");

  // 响应内容约束：一旦generated置位，交给IFU的全部身份、数据和错误字段必须已知。
  a_generated_lookup_response_is_known :
  assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      lookup_response_generated_q |-> !$isunknown(
      lookup_resp_q
  ))
  else $error("I-cache generated a lookup response containing unknown values");
`endif

  // 定向验证清单：每项都应同时检查握手次数、payload身份和array写入次数，不能只检查
  // 最终指令值。这些是模块接口契约的回归检查，不是尚未实现的RTL逻辑。
  // 1. cacheable miss：发送8个word，确认data write恰好8次、metadata只在最后一次出现；
  // 2. critical word分别为0、3、7：确认lookup response在对应beat后出现，而不是固定等RLAST；
  // 3. IFU反压：critical响应出现后保持ready=0若干拍，确认payload稳定且剩余refill继续；
  // 4. uncached：只发一个refill word，返回正确身份，但data/metadata写入次数均为0；
  // 5. fault位于critical之前、critical本身和critical之后：都不得安装line，且整个burst
  //    必须排空到last_word；每个miss最终只能向IFU交付一个响应；
  // 6. single-MSHR：非IDLE期间miss_req_ready_o始终为0；
  // 7. transaction_index错误：未来多MSHR前至少用assert捕获不属于当前表项的response；
  // 8. redirect/epoch不在本模块丢弃：验证响应原样带回旧epoch，再由IFU directed test确认
  //    旧响应不会进入fetch buffer。

endmodule
