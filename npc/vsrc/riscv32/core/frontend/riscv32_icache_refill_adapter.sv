// Converts one local I-cache refill transaction into ordered AXI4-Lite word reads.
module riscv32_icache_refill_adapter
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  icache_refill_req_t  refill_req_i,
    input  logic                refill_req_valid_i,
    output logic                refill_req_ready_o,

    output icache_refill_resp_t refill_resp_o,
    output logic                refill_resp_valid_o,
    input  logic                refill_resp_ready_i,

    output axi_lite_addr_t lower_axi_ar_o,
    output logic           lower_axi_arvalid_o,
    input  logic           lower_axi_arready_i,
    input  axi_lite_r_t    lower_axi_r_i,
    input  logic           lower_axi_rvalid_i,
    output logic           lower_axi_rready_o
);

  // TODO(ICACHE-REFILL-1): 在本TODO正下方定义四个状态和事务寄存器。
  // 建议状态：REFILL_IDLE、REFILL_SEND_ADDRESS、REFILL_WAIT_RESPONSE、
  // REFILL_HOLD_RESPONSE。需要保存：
  // - refill_req_q：当前line地址、critical word、word数量和transaction index；
  // - current_word_index_q：本次将要/正在读取的line内word编号；
  // - returned_word_count_q：已经向miss unit成功交付多少个word；
  // - refill_resp_q与refill_resp_present_q：下游反压时保存一个AXI读响应。
  //
  // 每个寄存器都定义对应_d。事务参数在req握手后保持到last response握手，不能从
  // 变化中的输入端口重新读取。

  // TODO(ICACHE-REFILL-2): 紧接声明之后定义握手事件和下一个word计算。
  // 建议事件名：refill_req_handshake、lower_axi_ar_handshake、
  // lower_axi_r_handshake、refill_resp_handshake。下一个word采用critical-word-first：
  //
  //   next_word_index = (current_word_index_q == ICACHE_WORDS_PER_LINE-1)
  //       ? '0 : current_word_index_q + 1'b1;
  //
  // 因为WORDS_PER_LINE是2的幂，也可让固定宽度加法自然回绕。不要用`%`把除法器语义
  // 带入RTL。AXI地址为line_base_addr + current_word_index * BYTE_LANES；BYTE_LANES=4
  // 时直接拼接或左移2位，不需要乘法器。

  // TODO(ICACHE-REFILL-3): 在本TODO正下方写三段式FSM的第一段：组合输出逻辑。
  // 先给所有输出默认值，再按state_q覆盖：
  // - IDLE：refill_req_ready_o=1；
  // - SEND_ADDRESS：保持ARVALID=1和AR payload稳定，直到AR握手；
  // - WAIT_RESPONSE：本地response buffer为空时RREADY=1。若refill_resp_ready_i=1，
  //   可以把AXI R响应同周期旁路成refill_resp，避免无条件多一拍；若下游不ready，
  //   仍必须在时钟沿保存到refill_resp_q；
  // - HOLD_RESPONSE：从refill_resp_q持续输出valid，直到下游握手。
  //
  // refill_resp.word_index=current_word_index_q；data=lower_axi_r_i.data；
  // access_fault由RRESP!=OKAY产生；last_word在
  // returned_word_count_q + 1 == refill_req_q.requested_word_count时置1。
  // fast bypass只能缩短响应路径，不能跳过response buffer这个反压后备路径。

  // TODO(ICACHE-REFILL-4): 在本TODO正下方写第二段：状态与数据next逻辑。
  // 完整转移规则：
  // 1. IDLE收到req握手：锁存请求，current_word=critical_word，count=0，转SEND。
  // 2. SEND_ADDRESS收到AR握手：转WAIT_RESPONSE。
  // 3. WAIT_RESPONSE收到R握手：构造响应。若下游同周期接收，则本word完成；否则保存
  //    响应并转HOLD_RESPONSE。
  // 4. 任一response真正与miss unit握手后，若last_word则回IDLE；否则count+1、
  //    current_word更新并转SEND_ADDRESS。
  // 5. RRESP错误仍作为一个有效response交付；第一版在错误word上令last_word=1，
  //    提前终止该refill，避免继续访问已经失败的line。
  //
  // 切勿在RVALID出现但refill_resp尚未握手时提前增加count，否则反压会重复或漏计word。

  // TODO(ICACHE-REFILL-5): 在本TODO正下方写第三段：按状态所有权分组的always_ff。
  // 一个block更新state；一个block更新请求和索引计数；一个block更新response buffer。
  // 所有组复位到零/IDLE。不要把无关寄存器集中到一个巨大always_ff中。

  // TODO(ICACHE-REFILL-6): 增加协议断言和模块级测试。
  // - ARVALID && !ARREADY时ARADDR/ARPROT稳定；
  // - RVALID && !RREADY时由slave保证R payload稳定，可在testbench检查；
  // - refill_resp_valid && !ready时refill_resp稳定；
  // - requested_word_count在1..WORDS_PER_LINE内；
  // - 一次line refill产生恰好请求的word数，word_index从critical开始环回且不重复；
  // - AXI4-Lite没有burst，因此每个word恰好发生一次AR和一次R握手。

endmodule
