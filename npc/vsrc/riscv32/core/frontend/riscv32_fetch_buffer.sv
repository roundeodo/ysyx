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

    // IFU作为上游生产者：entry和valid进入buffer，ready返回IFU。
    input  fetch_entry_t ifu_fetch_entry_i,
    input  logic         ifu_fetch_entry_valid_i,
    output logic         ifu_fetch_entry_ready_o,

    // IDU作为下游消费者：entry和valid离开buffer，ready由IDU返回。
    output fetch_entry_t idu_fetch_entry_o,
    output logic         idu_fetch_entry_valid_o,
    input  logic         idu_fetch_entry_ready_i,

    input logic flush_i
);

  // PC、指令、预测和异常作为一个fetch_entry_t原子排队，避免反压时字段错位。
  // 索引显式回绕，因此ENTRY_COUNT无需限制为2的幂。
  localparam int unsigned ENTRY_INDEX_W = (ENTRY_COUNT > 1) ? $clog2(ENTRY_COUNT) : 1;
  localparam int unsigned ENTRY_COUNT_W = $clog2(ENTRY_COUNT + 1);
  typedef logic [ENTRY_INDEX_W-1:0] entry_index_t;
  typedef logic [ENTRY_COUNT_W-1:0] entry_count_t;

  fetch_entry_t entry_array_q[ENTRY_COUNT];
  entry_index_t read_entry_index_q, read_entry_index_d;
  entry_index_t write_entry_index_q, write_entry_index_d;
  entry_count_t entry_count_q, entry_count_d;

  function automatic entry_index_t get_next_entry_index(input entry_index_t current_index);
    if (current_index == entry_index_t'(ENTRY_COUNT - 1)) begin
      return '0;
    end
    return current_index + entry_index_t'(1);
  endfunction

  initial begin
    if (ENTRY_COUNT < 1) $fatal(1, "fetch buffer ENTRY_COUNT must be at least 1");
  end
  // 接口握手与存储操作必须分开描述。空队列旁路时，上下游握手同时发生，但数据不写数组。
  logic queue_empty;
  logic queue_full;
  logic empty_queue_bypass_active;
  logic ifu_fetch_entry_handshake_occurred;
  logic idu_fetch_entry_handshake_occurred;
  logic enqueue_to_storage_occurred;
  logic dequeue_from_storage_occurred;
  // 空队列直接旁路IFU输入，避免增加取指交付延迟；非空时输出只能来自FIFO队首。
  // 满队列若同周期出队，仍允许IFU入队，从而维持每周期一个entry的稳态吞吐率。
  // 旁路会形成IFU到IDU的组合路径，前端变宽后应根据时序结果决定是否增加旁路开关。
  always_comb begin
    queue_empty               = (entry_count_q == entry_count_t'(0));
    queue_full                = (entry_count_q == entry_count_t'(ENTRY_COUNT));
    empty_queue_bypass_active = queue_empty;
  end

  always_comb begin
    idu_fetch_entry_o = empty_queue_bypass_active
                      ? ifu_fetch_entry_i
                      : entry_array_q[read_entry_index_q];
    idu_fetch_entry_valid_o =
        !flush_i && (empty_queue_bypass_active ? ifu_fetch_entry_valid_i : 1'b1);

    ifu_fetch_entry_ready_o =
        !flush_i && (!queue_full || (idu_fetch_entry_valid_o && idu_fetch_entry_ready_i));

    ifu_fetch_entry_handshake_occurred = ifu_fetch_entry_valid_i && ifu_fetch_entry_ready_o;
    idu_fetch_entry_handshake_occurred = idu_fetch_entry_valid_o && idu_fetch_entry_ready_i;
    enqueue_to_storage_occurred =
        ifu_fetch_entry_handshake_occurred
        && !(empty_queue_bypass_active && idu_fetch_entry_handshake_occurred);
    dequeue_from_storage_occurred      = idu_fetch_entry_handshake_occurred && !queue_empty;
  end

  // 指针只响应真正的数组入队/出队。flush具有最高优先级，只清控制状态；旧payload因
  // entry_count_q归零而不可见，无需为整个数组构造复位网络。
  always_comb begin
    read_entry_index_d  = read_entry_index_q;
    write_entry_index_d = write_entry_index_q;
    entry_count_d       = entry_count_q;

    if (enqueue_to_storage_occurred) begin
      write_entry_index_d = get_next_entry_index(write_entry_index_q);
    end
    if (dequeue_from_storage_occurred) begin
      read_entry_index_d = get_next_entry_index(read_entry_index_q);
    end

    unique case ({
      enqueue_to_storage_occurred, dequeue_from_storage_occurred
    })
      2'b10:   entry_count_d = entry_count_q + entry_count_t'(1);
      2'b01:   entry_count_d = entry_count_q - entry_count_t'(1);
      default: ;
    endcase

    if (flush_i) begin
      read_entry_index_d  = '0;
      write_entry_index_d = '0;
      entry_count_d       = '0;
    end
  end
  // 控制状态需要复位；payload数组仅在真正入队时写入，由entry_count_q管理有效性。
  // 两类寄存器分开更新，便于将payload数组替换为SRAM或更深的fetch packet queue。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_entry_index_q  <= '0;
      write_entry_index_q <= '0;
      entry_count_q       <= '0;
    end else begin
      read_entry_index_q  <= read_entry_index_d;
      write_entry_index_q <= write_entry_index_d;
      entry_count_q       <= entry_count_d;
    end
  end

  always_ff @(posedge clk_i) begin
    if (enqueue_to_storage_occurred) begin
      entry_array_q[write_entry_index_q] <= ifu_fetch_entry_i;
    end
  end
  // 协议断言覆盖容量边界、反压稳定性和flush清空行为；它们不进入综合结果。
`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    entry_count_q <= entry_count_t'(ENTRY_COUNT))
    else $error("fetch buffer entry count exceeded capacity");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    queue_empty |-> !dequeue_from_storage_occurred)
    else $error("fetch buffer dequeued storage while empty");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (queue_full && !dequeue_from_storage_occurred) |-> !enqueue_to_storage_occurred)
    else $error("fetch buffer enqueued storage while full without dequeue");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (idu_fetch_entry_valid_o && !idu_fetch_entry_ready_i && !flush_i)
    |=> (flush_i || (idu_fetch_entry_valid_o && $stable(idu_fetch_entry_o))))
    else $error("fetch buffer output changed while IDU applied backpressure");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> (entry_count_q == entry_count_t'(0)))
    else $error("fetch buffer was not empty after flush");
`endif

endmodule
