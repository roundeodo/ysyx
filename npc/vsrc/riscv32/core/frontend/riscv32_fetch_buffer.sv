// IFU响应与IDU消费之间的小型弹性队列。
//
// 本模块只负责解耦上下游反压和保存已经完成的fetch entry，不参与PC选择、cache命中
// 或指令译码。空队列允许同周期fast bypass，发生反压时退回寄存器存储。未来扩大取指
// 宽度或加入分支预测后，这里可以演进为fetch packet queue，而无需改变I-cache阵列。
module riscv32_fetch_buffer
  import riscv32_pkg::*;
#(
    parameter int unsigned ENTRY_COUNT = 2
) (
    input logic clk_i,
    input logic rst_ni,

    input  fetch_entry_t fetch_entry_i,
    input  logic         fetch_entry_valid_i,
    output logic         fetch_entry_ready_o,

    output fetch_entry_t fetch_entry_o,
    output logic         fetch_entry_valid_o,
    input  logic         fetch_entry_ready_i,

    input logic flush_i
);

  // TODO(FETCH-BUFFER-1): 在本TODO正下方定义FIFO存储、状态寄存器和索引推进函数。
  //
  // 这个buffer保存的是已经完成取指的fetch_entry_t，而不是单独的instruction。PC、指令、
  // exception等信息必须作为同一entry一起排队，避免反压时不同指令的信息互相错位。
  // 建议直接抄写下面的声明骨架，再补齐分号：
  //
  //   localparam int unsigned ENTRY_INDEX_W = (ENTRY_COUNT > 1) ? $clog2(ENTRY_COUNT) : 1;
  //   localparam int unsigned ENTRY_COUNT_W = $clog2(ENTRY_COUNT + 1);
  //
  //   typedef logic [ENTRY_INDEX_W-1:0] entry_index_t;
  //   typedef logic [ENTRY_COUNT_W-1:0] entry_count_t;
  //
  //   fetch_entry_t entry_array_q[ENTRY_COUNT];
  //   entry_index_t read_entry_index_q,  read_entry_index_d;
  //   entry_index_t write_entry_index_q, write_entry_index_d;
  //   entry_count_t entry_count_q,        entry_count_d;
  //
  // 指针不能直接依赖自然溢出，因为ENTRY_COUNT不一定是2的幂。用函数显式回绕：
  //
  //   function automatic entry_index_t get_next_entry_index(input entry_index_t current_index);
  //     if (current_index == entry_index_t'(ENTRY_COUNT - 1)) begin
  //       return '0;
  //     end
  //     return current_index + entry_index_t'(1);
  //   endfunction
  //
  // ENTRY_COUNT为0没有物理意义。该检查只在仿真/elaboration阶段生效，不进入数据通路：
  //
  //   initial begin
  //     if (ENTRY_COUNT < 1) $fatal(1, "fetch buffer ENTRY_COUNT must be at least 1");
  //   end

  // TODO(FETCH-BUFFER-2): 在本TODO正下方声明队列状态和传输事件。
  //
  // 这里必须区分“接口发生握手”和“数据真正写入FIFO”。空队列且下游ready时，entry可以
  // 直接旁路给IDU，此时input/output两个握手同时发生，但不能把这条entry再写入数组。
  // 建议声明：
  //
  //   logic queue_empty;
  //   logic queue_full;
  //   logic empty_queue_bypass_active;
  //   logic input_handshake_occurred;
  //   logic output_handshake_occurred;
  //   logic enqueue_to_storage_occurred;
  //   logic dequeue_from_storage_occurred;
  //
  // 名称中的occurred表示“本周期valid && ready这一事件是否发生”，不是保存历史结果。

  // TODO(FETCH-BUFFER-3): 在本TODO正下方实现接口输出和空队列fast bypass组合逻辑。
  //
  // 先得到队列状态：
  //
  //   queue_empty = (entry_count_q == entry_count_t'(0));
  //   queue_full  = (entry_count_q == entry_count_t'(ENTRY_COUNT));
  //   empty_queue_bypass_active = queue_empty;
  //
  // 输出选择规则：非空时只能返回队首；空队列时直接返回当前输入。flush期间valid必须为0，
  // 防止已经被redirect取消的旧取指在清空时又被IDU接收：
  //
  //   fetch_entry_o = empty_queue_bypass_active
  //                 ? fetch_entry_i
  //                 : entry_array_q[read_entry_index_q];
  //   fetch_entry_valid_o = !flush_i
  //                       && (empty_queue_bypass_active ? fetch_entry_valid_i : 1'b1);
  //
  // 输入ready规则：队列未满时可以接收；队列已满但队首本周期会被下游取走时，也可以同时
  // dequeue/enqueue。这样不会在满队列边界无谓插入气泡：
  //
  //   fetch_entry_ready_o = !flush_i
  //                       && (!queue_full
  //                           || (fetch_entry_valid_o && fetch_entry_ready_i));
  //
  // 最后定义握手。空队列旁路成功时两个握手同时发生，但不访问存储数组：
  //
  //   input_handshake_occurred  = fetch_entry_valid_i && fetch_entry_ready_o;
  //   output_handshake_occurred = fetch_entry_valid_o && fetch_entry_ready_i;
  //   enqueue_to_storage_occurred = input_handshake_occurred
  //                               && !(empty_queue_bypass_active
  //                                    && output_handshake_occurred);
  //   dequeue_from_storage_occurred = output_handshake_occurred && !queue_empty;
  //
  // 高性能意义：旁路把空队列命中路径的额外延迟降为0；满队列同拍出入维持1 entry/cycle
  // 吞吐率。代价是形成IFU valid/data到IDU的组合路径，后续前端变宽或时序不收敛时，应将
  // fast bypass做成可配置参数，而不是改变valid-ready语义。

  // TODO(FETCH-BUFFER-4): 在本TODO正下方实现指针和entry数量的next-state组合逻辑。
  //
  // 推荐一个独立always_comb，先保持原值，再根据存储层面的enqueue/dequeue更新：
  //
  //   always_comb begin
  //     read_entry_index_d  = read_entry_index_q;
  //     write_entry_index_d = write_entry_index_q;
  //     entry_count_d       = entry_count_q;
  //
  //     if (enqueue_to_storage_occurred) begin
  //       write_entry_index_d = get_next_entry_index(write_entry_index_q);
  //     end
  //     if (dequeue_from_storage_occurred) begin
  //       read_entry_index_d = get_next_entry_index(read_entry_index_q);
  //     end
  //
  //     unique case ({enqueue_to_storage_occurred, dequeue_from_storage_occurred})
  //       2'b10: entry_count_d = entry_count_q + entry_count_t'(1);
  //       2'b01: entry_count_d = entry_count_q - entry_count_t'(1);
  //       default: ; // 同时出入或都不发生时，entry数量不变。
  //     endcase
  //
  //     if (flush_i) begin
  //       read_entry_index_d  = '0;
  //       write_entry_index_d = '0;
  //       entry_count_d       = '0;
  //     end
  //   end
  //
  // flush优先级最高。无需清零entry_array_q的数据位，因为entry_count_q归零后旧内容不可见；
  // 这可避免为无意义的数据清零制造大扇出复位网络。

  // TODO(FETCH-BUFFER-5): 在本TODO正下方实现按职责分组的时序逻辑。
  //
  // 指针和数量属于队列控制状态，放在同一个always_ff：
  //
  //   always_ff @(posedge clk_i or negedge rst_ni) begin
  //     if (!rst_ni) begin
  //       read_entry_index_q  <= '0;
  //       write_entry_index_q <= '0;
  //       entry_count_q       <= '0;
  //     end else begin
  //       read_entry_index_q  <= read_entry_index_d;
  //       write_entry_index_q <= write_entry_index_d;
  //       entry_count_q       <= entry_count_d;
  //     end
  //   end
  //
  // entry数组只在数据真正进入存储时写入，不需要reset，也不受flush直接改写：
  //
  //   always_ff @(posedge clk_i) begin
  //     if (enqueue_to_storage_occurred) begin
  //       entry_array_q[write_entry_index_q] <= fetch_entry_i;
  //     end
  //   end
  //
  // 这种分组不是形式要求，而是体现状态所有权：控制寄存器有复位，payload存储靠有效状态
  // 屏蔽旧数据。将来替换成SRAM或更深的fetch packet queue时，存储接口也更容易抽离。

  // TODO(FETCH-BUFFER-6): 在本TODO正下方加入仿真断言。
  //
  // 至少检查以下不变量。断言建议放在`ifndef SYNTHESIS中，综合时完全移除：
  //
  //   1. entry_count_q始终不超过ENTRY_COUNT；
  //   2. 空队列不能发生dequeue_from_storage_occurred；
  //   3. 满队列若没有dequeue，就不能发生enqueue_to_storage_occurred；
  //   4. 输出valid且下游未ready时，只要没有flush，下一周期输出entry必须保持稳定；
  //   5. flush后的下一周期entry_count_q必须为0且fetch_entry_valid_o必须为0，除非同一
  //      周期出现了新的合法输入。当前实现flush期间ready为0，所以不会接收新输入。
  //
  // 可参考以下骨架：
  //
  //   `ifndef SYNTHESIS
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     entry_count_q <= entry_count_t'(ENTRY_COUNT));
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     queue_empty |-> !dequeue_from_storage_occurred);
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     (queue_full && !dequeue_from_storage_occurred)
  //     |-> !enqueue_to_storage_occurred);
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     (fetch_entry_valid_o && !fetch_entry_ready_i && !flush_i)
  //     |=> (flush_i || (fetch_entry_valid_o && $stable(fetch_entry_o))));
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     flush_i |=> (entry_count_q == entry_count_t'(0)));
  //   `endif
  //
  // 注意：断言检查的是协议和队列不变量，不要把具体PC值写死。

  // TODO(FETCH-BUFFER-7): 完成RTL后编写定向测试，并删除本TODO。
  //
  // 最少覆盖以下序列：
  //   - 空队列且下游ready：输入同周期旁路输出，count保持0；
  //   - 空队列且下游反压：输入被写入entry_array，count变为1；
  //   - 连续输入直到满，再保持若干周期反压：输出entry及顺序不变；
  //   - 满队列同周期出入：count保持ENTRY_COUNT，旧队首先输出，新entry写入队尾；
  //   - 队列中有多条entry时flush：下一周期全部失效，之后第一条新entry可正常通过；
  //   - PC、instruction和exception字段使用不同模式，确认整个fetch_entry_t原子地排队。

endmodule
