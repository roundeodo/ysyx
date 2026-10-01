// 顺序分配/退休，四端口按身份完成。payload 无复位；有效位是唯一生命周期依据。
module riscv32_rob
  import riscv32_pkg::*;
(
    input  logic                                      clk_i,
    rst_ni,
    input  logic                                      flush_i,
    input  decoded_uop_t                              allocate_uop_i,
    input  logic                                      allocate_valid_i,
    output logic                                      allocate_ready_o,
    output backend_tag_t                              allocate_tag_o,
    input  backend_completion_t                       alu_i,
    multiply_i,
    divide_i,
    memory_i,
    input  logic                                      recover_i,
    input  backend_tag_t                              recover_tag_i,
    output logic                [BACKEND_ENTRIES-1:0] cancel_vector_o,
    output execute_producer_t                         producer_array_o[BACKEND_ENTRIES],
    output writeback_result_t                         head_o,
    output logic                                      head_valid_o,
    input  logic                                      head_ready_i,
    output backend_tag_t                              head_tag_o,
    output logic                                      empty_o,
    output logic                [    BACKEND_TAG_W:0] count_o
);
  backend_completion_t completion_array[BACKEND_PORTS];
  assign completion_array[0] = alu_i;
  assign completion_array[1] = multiply_i;
  assign completion_array[2] = divide_i;
  assign completion_array[3] = memory_i;
  backend_tag_t head_index_q, tail_index_q;
  logic [BACKEND_TAG_W:0] count_q;
  logic [BACKEND_ENTRIES-1:0] present_vector_q, completed_vector_q, completion_vector;
  writeback_result_t result_array_q[BACKEND_ENTRIES];
  writeback_result_t completed_result_array[BACKEND_ENTRIES];
  logic retire_handshake, allocation_handshake;
  backend_tag_t recovery_distance;

  assign head_tag_o = head_index_q;
  assign allocate_tag_o = tail_index_q;
  assign empty_o = (count_q == 0);
  assign count_o = count_q;
  assign retire_handshake = head_valid_o && head_ready_i;
  assign allocate_ready_o = (count_q < (BACKEND_TAG_W + 1)'(BACKEND_ENTRIES)) || retire_handshake;
  assign allocation_handshake = allocate_valid_i && allocate_ready_o;
  assign recovery_distance = recover_tag_i - head_index_q;

  // 恢复只取消分支之后的条目。环形距离在容量为 2 的幂时自然截断。
  for (genvar slot = 0; slot < BACKEND_ENTRIES; slot++) begin : gen_entry
    backend_tag_t distance;
    assign distance = backend_tag_t'(slot) - head_index_q;
    assign cancel_vector_o[slot] = present_vector_q[slot] && recover_i &&
                           (distance > recovery_distance);
    always_comb begin
      completed_result_array[slot] = result_array_q[slot];
      completion_vector[slot]      = 1'b0;
      for (int port = 0; port < BACKEND_PORTS; port++) begin
        if (completion_array[port].valid && completion_array[port].tag == backend_tag_t'(slot)) begin
          completion_vector[slot]                   = 1'b1;
          completed_result_array[slot].result       = completion_array[port].value;
          completed_result_array[slot].csr_wdata    = completion_array[port].csr_wdata;
          completed_result_array[slot].memory_addr  = completion_array[port].memory_addr;
          completed_result_array[slot].memory_rdata = completion_array[port].memory_rdata;
          completed_result_array[slot].memory_wdata = completion_array[port].memory_wdata;
          completed_result_array[slot].memory_wmask = completion_array[port].memory_wmask;
          // MUL/DIV 不产生异常，保留原元数据；不为无效 cause/tval 添加写入与退休 mux。
          if ((port == 0) || (port == 3)) begin
            completed_result_array[slot].uop.exception_valid = completion_array[port].exception_valid;
            completed_result_array[slot].uop.exception_cause = completion_array[port].exception_cause;
            completed_result_array[slot].uop.exception_tval = completion_array[port].exception_tval;
          end
          // MUL/DIV 总是 PC+4，无须在算法流水中复制完整 PC。
          if ((port == 0) || (port == 3))
            completed_result_array[slot].next_pc = completion_array[port].next_pc;
        end
      end
    end
    assign producer_array_o[slot].present = present_vector_q[slot];
    assign producer_array_o[slot].writes_rd = result_array_q[slot].uop.writes_rd;
    assign producer_array_o[slot].rd = result_array_q[slot].uop.rd;
    assign producer_array_o[slot].serializing = result_array_q[slot].uop.serializing;
    assign producer_array_o[slot].value = completed_result_array[slot].result;
    assign producer_array_o[slot].forwardable = (completed_vector_q[slot] || completion_vector[slot]) &&
                                            !completed_result_array[slot].uop.exception_valid;

    always_ff @(posedge clk_i) begin
      if (present_vector_q[slot] && completion_vector[slot])
        result_array_q[slot] <= completed_result_array[slot];
      // 满队列的 retire_handshake+allocation_handshake 可复用同一槽；新分配优先于老结果写入。
      if (allocation_handshake && tail_index_q == backend_tag_t'(slot)) begin
        result_array_q[slot]         <= '0;
        result_array_q[slot].uop     <= allocate_uop_i;
        result_array_q[slot].next_pc <= allocate_uop_i.pc + program_counter_t'(INSTRUCTION_BYTES);
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        present_vector_q[slot]   <= 1'b0;
        completed_vector_q[slot] <= 1'b0;
      end else begin
        if (present_vector_q[slot] && completion_vector[slot]) completed_vector_q[slot] <= 1'b1;
        if (retire_handshake && head_index_q == backend_tag_t'(slot))
          present_vector_q[slot] <= 1'b0;
        if (allocation_handshake && tail_index_q == backend_tag_t'(slot)) begin
          present_vector_q[slot]   <= 1'b1;
          completed_vector_q[slot] <= 1'b0;
        end
        if (cancel_vector_o[slot] || flush_i) present_vector_q[slot] <= 1'b0;
      end
    end
  end

  // 已寄存的 ALU 结果和流水 MUL 可在队首完成当拍退休。
  // Commit 反压时照常写入原 ROB 项，下一拍由存储结果接续；不增加缓冲。
  // DIV/LSU 保留完成寄存边界，避免退休授权反馈到同拍派发与返回。
  logic alu_head_completion, multiply_head_completion;
  assign alu_head_completion = alu_i.valid && alu_i.tag == head_index_q;
  assign multiply_head_completion = multiply_i.valid && multiply_i.tag == head_index_q;
  assign head_valid_o = present_vector_q[head_index_q] &&
                        (completed_vector_q[head_index_q] ||
                         alu_head_completion || multiply_head_completion);
  assign head_o.result = alu_head_completion ? alu_i.value :
                         multiply_head_completion ? multiply_i.value :
                         result_array_q[head_index_q].result;
  assign head_o.next_pc = alu_head_completion ? alu_i.next_pc :
                          result_array_q[head_index_q].next_pc;
  assign head_o.csr_wdata = alu_head_completion ? alu_i.csr_wdata :
                            result_array_q[head_index_q].csr_wdata;
  assign head_o.memory_addr  = result_array_q[head_index_q].memory_addr;
  assign head_o.memory_rdata = result_array_q[head_index_q].memory_rdata;
  assign head_o.memory_wdata = result_array_q[head_index_q].memory_wdata;
  assign head_o.memory_wmask = result_array_q[head_index_q].memory_wmask;
  always_comb begin
    head_o.uop = result_array_q[head_index_q].uop;
    if (alu_head_completion) begin
      head_o.uop.exception_valid = alu_i.exception_valid;
      head_o.uop.exception_cause = alu_i.exception_cause;
      head_o.uop.exception_tval  = alu_i.exception_tval;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_index_q <= '0;
      tail_index_q <= '0;
      count_q      <= '0;
    end else if (flush_i) begin
      head_index_q <= '0;
      tail_index_q <= '0;
      count_q      <= '0;
    end else begin
      if (retire_handshake) head_index_q <= head_index_q + 1'b1;
      if (allocation_handshake) tail_index_q <= tail_index_q + 1'b1;
      count_q <= count_q + (BACKEND_TAG_W+1)'(allocation_handshake) - (BACKEND_TAG_W+1)'(retire_handshake);
      if (recover_i) begin
        tail_index_q <= recover_tag_i + 1'b1;
        count_q      <= {1'b0, recovery_distance} + 1'b1 - (BACKEND_TAG_W + 1)'(retire_handshake);
      end
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (head_valid_o && !head_ready_i && !flush_i) |=> (head_valid_o && $stable(
      head_o
  )));
  initial assert ((BACKEND_ENTRIES == 2) || (BACKEND_ENTRIES == 4) || (BACKEND_ENTRIES == 8));
  assert property (@(posedge clk_i) disable iff (!rst_ni) count_q == $countones(present_vector_q));
  assert property (@(posedge clk_i) disable iff (!rst_ni) !(allocation_handshake && (flush_i || recover_i)));
  for (genvar p = 0; p < BACKEND_PORTS; p++) begin : gen_completion_check
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      completion_array[p].valid |-> (present_vector_q[completion_array[p].tag] && !completed_vector_q[completion_array[p].tag]));
    for (genvar q = p + 1; q < BACKEND_PORTS; q++) begin : gen_unique
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        (completion_array[p].valid && completion_array[q].valid) |->
        (completion_array[p].tag != completion_array[q].tag));
    end
  end
`endif
endmodule
