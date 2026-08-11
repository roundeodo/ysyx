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

  // TODO(FETCH-BUFFER-1): 在本TODO正下方定义FIFO存储和指针。
  // 建议声明entry_array_q[ENTRY_COUNT]、read_index_q、write_index_q和
  // entry_count_q。索引宽度用(ENTRY_COUNT>1)?$clog2(ENTRY_COUNT):1推导。当前模块只
  // 实现ENTRY_COUNT>=1的队列语义，不在数据通路中增加参数检查逻辑。数组名必须体现
  // 它是集合，index名必须体现编码索引。

  // TODO(FETCH-BUFFER-2): 在本TODO正下方定义输入、输出握手和空队列fast bypass。
  // 队列非空时输出entry_array_q[read_index_q]；队列为空时可将输入直接旁路到输出：
  //
  //   bypass_active = (entry_count_q == 0);
  //   fetch_entry_o = bypass_active ? fetch_entry_i : entry_array_q[read_index_q];
  //   fetch_entry_valid_o = bypass_active ? fetch_entry_valid_i : 1'b1;
  //
  // ready必须同时考虑队列空间和本周期dequeue。若空队列输入/输出同周期握手，则数据
  // 直接通过且不写FIFO。不得形成跨IFU、buffer、IDU的ready-to-valid组合环。

  // TODO(FETCH-BUFFER-3): 在本TODO正下方实现next逻辑。
  // 分别处理四种事件：仅enqueue、仅dequeue、同时enqueue/dequeue、无传输。
  // 非空时同时enqueue/dequeue保持count不变并各自推进指针；空队列旁路成功时指针和
  // count都不变。flush优先级最高，在一个时钟沿把count和指针清零，旧entry不再有效。

  // TODO(FETCH-BUFFER-4): 在本TODO正下方实现分组always_ff。
  // entry array只在真正enqueue到存储时写；pointer/count单独更新。完成后用定向测试覆盖
  // 空旁路、满队列同时出入、连续反压和redirect flush。

endmodule
