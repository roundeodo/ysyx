// IFU响应与IDU消费之间的小型弹性队列。
//
// 本模块只负责解耦上下游反压和保存已经完成的fetch entry，不参与PC选择、cache命中
// 或指令译码。IFU响应必须先登记到队列，再由IDU消费，从而切断I-cache响应经过译码、
// 执行和提交后又组合反馈到前端的长路径。未来扩大取指宽度或加入分支预测后，这里可以
// 演进为fetch packet queue，而无需改变I-cache阵列。
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
  // 接口握手与存储操作必须分开描述。队列是寄存器化流水边界，不提供跨越整个核心的
  // 空队列旁路；这种旁路会把前端响应与当拍提交/redirect组合成环路并恶化关键路径。
  logic queue_empty;
  logic queue_full;
  logic ifu_fetch_entry_handshake_occurred;
  logic idu_fetch_entry_handshake_occurred;
  logic enqueue_to_storage_occurred;
  logic dequeue_from_storage_occurred;

  always_comb begin
    queue_empty = (entry_count_q == entry_count_t'(0));
    queue_full  = (entry_count_q == entry_count_t'(ENTRY_COUNT));
  end

  // 输出始终来自已经登记的队首。flush不能组合压低队首valid，否则当前队首指令产生的
  // redirect会反向改变自身valid并形成组合环；flush在本拍阻止新入队，并在时钟沿清空队列。
  // 满队列若同周期出队，仍允许IFU入队，从而保持每周期一个entry的稳态吞吐率。
  always_comb begin
    idu_fetch_entry_o       = entry_array_q[read_entry_index_q];
    idu_fetch_entry_valid_o = !queue_empty;

    ifu_fetch_entry_ready_o =
        !flush_i && (!queue_full || (idu_fetch_entry_valid_o && idu_fetch_entry_ready_i));

    ifu_fetch_entry_handshake_occurred = ifu_fetch_entry_valid_i && ifu_fetch_entry_ready_o;
    idu_fetch_entry_handshake_occurred = idu_fetch_entry_valid_o && idu_fetch_entry_ready_i;
    enqueue_to_storage_occurred        = ifu_fetch_entry_handshake_occurred;
    dequeue_from_storage_occurred      = idu_fetch_entry_handshake_occurred;
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
  // 协议断言覆盖容量边界、寄存器化边界、反压稳定性和flush清空行为；它们不进入综合结果。
`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    entry_count_q <= entry_count_t'(ENTRY_COUNT))
    else $error("fetch buffer entry count exceeded capacity");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    queue_empty |-> !dequeue_from_storage_occurred)
    else $error("fetch buffer dequeued storage while empty");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    queue_empty |-> !idu_fetch_entry_valid_o)
    else $error("fetch buffer exposed an unregistered bypass entry while empty");

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
