// Blocking I-cache miss tracker. The first version contains one MSHR.
module riscv32_icache_miss_unit
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  icache_miss_req_t   miss_req_i,
    input  logic               miss_req_valid_i,
    output logic               miss_req_ready_o,

    output icache_lookup_resp_t lookup_resp_o,
    output logic                lookup_resp_valid_o,
    input  logic                lookup_resp_ready_i,

    output icache_refill_req_t  refill_req_o,
    output logic                refill_req_valid_o,
    input  logic                refill_req_ready_i,
    input  icache_refill_resp_t refill_resp_i,
    input  logic                refill_resp_valid_i,
    output logic                refill_resp_ready_o,

    output logic                data_write_valid_o,
    output icache_set_index_t   data_write_set_index_o,
    output icache_way_index_t   data_write_way_index_o,
    output icache_word_index_t  data_write_word_index_o,
    output logic [XLEN-1:0]     data_write_word_data_o,

    output logic               metadata_write_valid_o,
    output icache_set_index_t  metadata_write_set_index_o,
    output icache_way_index_t  metadata_write_way_index_o,
    output icache_tag_t        metadata_write_tag_o,
    output logic               metadata_write_line_present_o,

    output logic          miss_transaction_present_o,
    output icache_event_t event_o
);

  // TODO(ICACHE-MISS-1): 在本TODO正下方定义单MSHR状态和寄存器。
  // 建议状态：MISS_IDLE、MISS_SEND_REFILL_REQUEST、MISS_RECEIVE_REFILL、
  // MISS_COMPLETE。保存miss_req_q、received_word_present_vector_q、
  // lookup_resp_q和lookup_resp_present_q。`present`表示寄存器中当前保存了有效内容，
  // 不是“事务成功”。
  //
  // 第一版只允许一个miss，所以miss_req_ready_o仅在IDLE有效。接口中仍保留
  // transaction_index，使第二版扩展多个MSHR时无需重写refill adapter契约。

  // TODO(ICACHE-MISS-2): 在本TODO正下方写第一段组合输出逻辑。
  // 默认关闭所有write/event/valid，再按状态覆盖：
  // - IDLE：miss_req_ready_o=1；
  // - SEND_REFILL_REQUEST：输出line-aligned base、critical word和word count。
  //   cacheable请求读完整line；uncached请求只读critical word；
  // - RECEIVE_REFILL：refill_resp_ready_o取决于能否保存/交付critical response。
  //   每个成功返回word产生一次data_write_valid_o，但只有cacheable请求才写array；
  // - COMPLETE：若lookup_resp_q尚未被IFU接收，稳定保持valid和payload。
  //
  // critical-word-first early restart：critical word返回时立即构造lookup response，
  // 不必等待其余7个word。但miss transaction仍保持present，继续完成整条line refill。
  // 若IFU反压，lookup_resp_q负责保存；不得因此重复向data array写同一个word。
  // 第一版early restart只提前交付critical word；miss unit仍占用唯一MSHR，直到整条line
  // 安装完成。因此它能重叠“关键指令后端执行”和“剩余line refill”，但不能在miss期间
  // 接收另一个lookup，也不能提供hit-under-miss。

  // TODO(ICACHE-MISS-3): 在本TODO正下方写第二段状态与数据next逻辑。
  // 关键规则：
  // 1. miss握手时锁存全部请求字段并清空received vector；
  // 2. refill request握手后进入RECEIVE；
  // 3. 每个refill response握手后设置对应received bit；若该word为critical，生成一次
  //    lookup response；若access_fault，则响应fault且禁止安装cache line；
  // 4. 只有所有请求word都成功接收后，才产生metadata_write_valid并把present写1；
  // 5. cache line安装完成后更新replacement policy的事件由I-cache顶层处理；
  // 6. uncached访问永远不写data/tag array；
  // 7. 事务完成且lookup response已被接收后才回IDLE。
  //
  // metadata present必须最后写，这是防止查询命中“部分填充line”的核心不变量。

  // TODO(ICACHE-MISS-4): 在本TODO正下方写第三段时序更新，并按三组拆分：
  // state；MSHR请求/received vector；lookup response buffer。每组只更新自己的_q。

  // TODO(ICACHE-MISS-5): 在本TODO正下方生成event_o。
  // miss_occurred在miss req握手时脉冲；refill_word_occurred在refill response握手时
  // 脉冲；refill_line_completed_occurred仅在完整cacheable line安装时脉冲。
  // lookup/hit/uncached事件由I-cache顶层生成，避免一个事件有多个驱动者。

  // TODO(ICACHE-MISS-6): 增加正确性断言和directed tests。
  // - 一个MSHR present时不得接受第二个miss；
  // - 一个word最多写一次；line present写1前所有word present；
  // - uncached和fault请求不写metadata present=1；
  // - response在valid&&!ready期间稳定；
  // - critical word为0和line末尾两种情况都验证环回顺序；
  // - redirect不会取消下层AXI握手，旧epoch丢弃由IFU完成。

endmodule
