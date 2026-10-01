// 在途指令与完成结果的有序队列。普通结果分配时保存，LSU/MUL/DIV 按标识返回。
module riscv_scoreboard
  import riscv_pkg::*;
#(
    parameter int unsigned ENTRY_COUNT = riscv_config_pkg::SCOREBOARD_ENTRY_COUNT
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input  execute_result_t   allocate_result_i,
    input  logic              allocate_completed_i,
    input  logic              allocate_valid_i,
    output logic              allocate_ready_o,
    output scoreboard_index_t allocate_index_o,

    input writeback_result_t  lsu_result_i,
    input logic               lsu_result_valid_i,
    input arithmetic_result_t multiply_result_i,
    input logic               multiply_result_valid_i,
    input arithmetic_result_t divide_result_i,
    input logic               divide_result_valid_i,

    input  decoded_uop_t       query_uop_i,
    output logic               rs1_pending_o,
    output logic               rs1_ready_o,
    output xlen_data_t         rs1_value_o,
    output scoreboard_index_t  rs1_index_o,
    output completion_source_e rs1_source_o,
    output logic               rs2_pending_o,
    output logic               rs2_ready_o,
    output xlen_data_t         rs2_value_o,
    output scoreboard_index_t  rs2_index_o,
    output completion_source_e rs2_source_o,
    output logic               serializing_present_o,
    output logic               empty_o,
    output logic               memory_issue_allowed_o,

    output writeback_result_t commit_result_o,
    output logic              commit_result_valid_o,
    input  logic              commit_result_ready_i
);
  scoreboard_index_t head_index_q;
  scoreboard_index_t tail_index_q;
  logic [ENTRY_COUNT-1:0] valid_vector_q;
  logic [ENTRY_COUNT-1:0] completed_vector_q;
  logic [ENTRY_COUNT-1:0] latest_writer_vector_q;
  logic [ENTRY_COUNT-1:0] memory_blocked_vector;
  // 只保存提交和依赖检查会读取的元数据，不复制预测、立即数和执行控制。
  typedef struct packed {
    program_counter_t pc;
    instruction_t     instruction;
    arch_reg_idx_t    rd;
    logic             writes_rd;
    logic             serializing;
    mem_uop_ctrl_t    mem_ctrl;
    logic             csr_write;
    system_op_e       system_op;
    logic             exception_valid;
    exception_cause_e exception_cause;
  } retirement_uop_t;
  typedef struct packed {
    retirement_uop_t  uop;
    xlen_data_t       result;
    program_counter_t next_pc;
  } scoreboard_entry_t;
  scoreboard_entry_t result_array_q[ENTRY_COUNT];
  completion_source_e completion_source_array_q[ENTRY_COUNT];

  // 已完成访存的跟踪信息跟随其结果槽，不再占住 LSU 的请求上下文。
  // 当前硬件消费者不读取这些字段；综合会删除未使用的跟踪存储，仿真仍完整检查提交。
  typedef struct packed {
    effective_addr_t   addr;
    core_data_t        write_data;
    core_byte_strobe_t write_mask;
  } retirement_memory_t;
  retirement_memory_t        memory_result_array_q[ENTRY_COUNT];

  // CSR 串行执行，宽写值只需一份。
  logic               [11:0] csr_addr_q;
  xlen_data_t                csr_wdata_q;
  logic                      allocate_handshake;
  logic                      commit_handshake;
  always_ff @(posedge clk_i) begin
    if (allocate_handshake && allocate_completed_i && allocate_result_i.uop.csr_ctrl.write_enable) begin
      csr_addr_q  <= allocate_result_i.uop.csr_ctrl.addr;
      csr_wdata_q <= allocate_result_i.csr_wdata;
    end
  end
  logic [ENTRY_COUNT-1:0] rs1_match_vector;
  logic [ENTRY_COUNT-1:0] rs2_match_vector;
  localparam int unsigned COMPLETION_PORT_COUNT = 3;
  arithmetic_result_t completion_array[COMPLETION_PORT_COUNT];
  logic [COMPLETION_PORT_COUNT-1:0] completion_valid_vector;
  logic [COMPLETION_PORT_COUNT-1:0] completion_exception_vector;
  assign completion_array[0] = {lsu_result_i.scoreboard_index, lsu_result_i.result};
  assign completion_array[1] = multiply_result_i;
  assign completion_array[2] = divide_result_i;
  assign completion_valid_vector = {
    divide_result_valid_i, multiply_result_valid_i, lsu_result_valid_i
  };
  assign completion_exception_vector = {2'b00, lsu_result_i.uop.exception_valid};

  function automatic scoreboard_index_t next_index(input scoreboard_index_t index);
    return (index == scoreboard_index_t'(ENTRY_COUNT - 1)) ? '0 : index + 1'b1;
  endfunction

  initial begin
    if (ENTRY_COUNT < 2 || ENTRY_COUNT != riscv_config_pkg::SCOREBOARD_ENTRY_COUNT)
      $fatal(1, "Scoreboard capacity must match the shared transaction-index configuration");
  end

  // valid 表示槽的所有权，completed 表示结果已经保存；无需重复保存一个占用计数器。
  assign empty_o            = !valid_vector_q[head_index_q];
  assign allocate_index_o   = tail_index_q;
  assign allocate_ready_o   = !valid_vector_q[tail_index_q] || commit_handshake;
  assign allocate_handshake = allocate_valid_i && allocate_ready_o && !flush_i;
  always_comb begin
    commit_result_o                           = '0;
    commit_result_o.scoreboard_index          = head_index_q;
    commit_result_o.uop.pc                    = result_array_q[head_index_q].uop.pc;
    commit_result_o.uop.instruction           = result_array_q[head_index_q].uop.instruction;
    commit_result_o.uop.rd                    = result_array_q[head_index_q].uop.rd;
    commit_result_o.uop.writes_rd             = result_array_q[head_index_q].uop.writes_rd;
    commit_result_o.uop.serializing           = result_array_q[head_index_q].uop.serializing;
    commit_result_o.uop.mem_ctrl              = result_array_q[head_index_q].uop.mem_ctrl;
    commit_result_o.uop.csr_ctrl.write_enable = result_array_q[head_index_q].uop.csr_write;
    commit_result_o.uop.csr_ctrl.addr         = csr_addr_q;
    commit_result_o.uop.system_op             = result_array_q[head_index_q].uop.system_op;
    commit_result_o.uop.exception_valid       = result_array_q[head_index_q].uop.exception_valid;
    commit_result_o.uop.exception_cause       = result_array_q[head_index_q].uop.exception_cause;
    // 异常载荷与正常结果互斥，不为每个槽额外保留一份 XLEN 位 tval。
    commit_result_o.uop.exception_tval = commit_result_o.uop.exception_valid ?
        result_array_q[head_index_q].result : '0;
    commit_result_o.result             = commit_result_o.uop.exception_valid ?
        '0 : result_array_q[head_index_q].result;
    commit_result_o.next_pc            = result_array_q[head_index_q].next_pc;
    commit_result_o.csr_wdata          = csr_wdata_q;
    if (commit_result_o.uop.mem_ctrl.cmd != MEM_CMD_NONE) begin
      commit_result_o.memory_addr  = memory_result_array_q[head_index_q].addr;
      commit_result_o.memory_wdata = memory_result_array_q[head_index_q].write_data;
      commit_result_o.memory_wmask = memory_result_array_q[head_index_q].write_mask;
      if (commit_result_o.uop.mem_ctrl.cmd == MEM_CMD_LOAD)
        commit_result_o.memory_rdata = core_data_t'(commit_result_o.result);
    end
  end
  assign commit_result_valid_o  = valid_vector_q[head_index_q] && completed_vector_q[head_index_q];
  assign commit_handshake       = commit_result_valid_o && commit_result_ready_i;
  assign memory_issue_allowed_o = !(|memory_blocked_vector);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_index_q <= '0;
      tail_index_q <= '0;
    end else if (flush_i) begin
      head_index_q <= '0;
      tail_index_q <= '0;
    end else begin
      if (commit_handshake) head_index_q <= next_index(head_index_q);
      if (allocate_handshake) tail_index_q <= next_index(tail_index_q);
    end
  end

  for (genvar entry_index = 0; entry_index < ENTRY_COUNT; entry_index++) begin : gen_entry
    logic allocate_entry;
    logic commit_entry;
    logic allocate_writer;
    logic replace_writer;
    logic [COMPLETION_PORT_COUNT-1:0] completion_select_vector;
    assign allocate_entry = allocate_handshake && tail_index_q == scoreboard_index_t'(entry_index);
    assign commit_entry   = commit_handshake && head_index_q == scoreboard_index_t'(entry_index);
    for (
        genvar port_index = 0; port_index < COMPLETION_PORT_COUNT; port_index++
    ) begin : gen_completion
      assign completion_select_vector[port_index] = completion_valid_vector[port_index] &&
          completion_array[port_index].scoreboard_index == scoreboard_index_t'(entry_index);
    end

    // 顺序读取操作数：查询只需最近的较老写者，旧写仍保存自己的结果供顺序提交。
    assign allocate_writer = allocate_handshake && allocate_result_i.uop.writes_rd && allocate_result_i.uop.rd != '0;
    assign replace_writer = allocate_writer &&
        allocate_result_i.uop.rd == result_array_q[entry_index].uop.rd;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) latest_writer_vector_q[entry_index] <= 1'b0;
      else if (flush_i) latest_writer_vector_q[entry_index] <= 1'b0;
      else if (allocate_entry) latest_writer_vector_q[entry_index] <= allocate_writer;
      else if (commit_entry || replace_writer) latest_writer_vector_q[entry_index] <= 1'b0;
    end

    // 普通操作在分配时已经算完；剩余未完成项只有 MUL/DIV 或 LSU。
    // MUL/DIV 无同步计算异常；LSU 自己保证请求顺序，错误响应不能交接下一请求。
    // 已记录异常和串行项继续阻止年轻访存，不从 LSU 响应组合地反馈请求授权。
    assign memory_blocked_vector[entry_index] = valid_vector_q[entry_index] &&
        (result_array_q[entry_index].uop.exception_valid ||
         result_array_q[entry_index].uop.serializing);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        valid_vector_q[entry_index]     <= 1'b0;
        completed_vector_q[entry_index] <= 1'b0;
      end else if (flush_i) begin
        valid_vector_q[entry_index]     <= 1'b0;
        completed_vector_q[entry_index] <= 1'b0;
      end else begin
        if (commit_entry) begin
          valid_vector_q[entry_index]     <= 1'b0;
          completed_vector_q[entry_index] <= 1'b0;
        end
        if (|completion_select_vector) completed_vector_q[entry_index] <= 1'b1;
        // 同槽提交与分配时，新指令决定完成状态；普通结果不再额外等一次完成回写。
        if (allocate_entry) begin
          valid_vector_q[entry_index]     <= 1'b1;
          completed_vector_q[entry_index] <= allocate_completed_i;
        end
      end
    end

    always_ff @(posedge clk_i) begin
      if (allocate_entry) begin
        completion_source_array_q[entry_index]          <= completion_source(allocate_result_i.uop);
        result_array_q[entry_index].uop.pc              <= allocate_result_i.uop.pc;
        result_array_q[entry_index].uop.instruction     <= allocate_result_i.uop.instruction;
        result_array_q[entry_index].uop.rd              <= allocate_result_i.uop.rd;
        result_array_q[entry_index].uop.writes_rd       <= allocate_result_i.uop.writes_rd;
        result_array_q[entry_index].uop.serializing     <= allocate_result_i.uop.serializing;
        result_array_q[entry_index].uop.mem_ctrl        <= allocate_result_i.uop.mem_ctrl;
        result_array_q[entry_index].uop.csr_write       <= allocate_result_i.uop.csr_ctrl.write_enable;
        result_array_q[entry_index].uop.system_op       <= allocate_result_i.uop.system_op;
        result_array_q[entry_index].uop.exception_valid <= allocate_result_i.uop.exception_valid;
        result_array_q[entry_index].uop.exception_cause <= allocate_result_i.uop.exception_cause;
        result_array_q[entry_index].next_pc             <= allocate_result_i.next_pc;
      end
      if (completion_select_vector[0]) begin
        result_array_q[entry_index].result              <= lsu_result_i.uop.exception_valid ?
            lsu_result_i.uop.exception_tval : lsu_result_i.result;
        memory_result_array_q[entry_index].addr         <= lsu_result_i.memory_addr;
        memory_result_array_q[entry_index].write_data   <= lsu_result_i.memory_wdata;
        memory_result_array_q[entry_index].write_mask   <= lsu_result_i.memory_wmask;
        result_array_q[entry_index].uop.exception_valid <= lsu_result_i.uop.exception_valid;
        result_array_q[entry_index].uop.exception_cause <= lsu_result_i.uop.exception_cause;
      end
      if (completion_select_vector[1])
        result_array_q[entry_index].result <= multiply_result_i.result;
      if (completion_select_vector[2]) result_array_q[entry_index].result <= divide_result_i.result;
      if (allocate_entry && allocate_completed_i)
        result_array_q[entry_index].result <= allocate_result_i.uop.exception_valid ?
            allocate_result_i.uop.exception_tval : allocate_result_i.result;
    end

`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
      (|completion_select_vector) |->
        (valid_vector_q[entry_index] && !completed_vector_q[entry_index] &&
         $onehot(
        completion_select_vector
    )))
    else $error("Completion has no live owner, is duplicated, or collides with another FU");
`endif
  end

  // 先匹配生产者，再直接选择已保存值或 LSU/MUL/DIV 返回总线。
  // 最近写者标志保证源匹配唯一；较老同名结果无论何时返回，都不能重新参与前递。
  always_comb begin
    rs1_match_vector      = '0;
    rs2_match_vector      = '0;
    rs1_ready_o           = 1'b0;
    rs2_ready_o           = 1'b0;
    rs1_value_o           = '0;
    rs1_index_o           = '0;
    rs1_source_o          = COMPLETION_LSU;
    rs2_source_o          = COMPLETION_LSU;
    rs2_index_o           = '0;
    rs2_value_o           = '0;
    serializing_present_o = 1'b0;
    for (int unsigned entry_index = 0; entry_index < ENTRY_COUNT; entry_index++) begin
      if (valid_vector_q[entry_index]) begin
        serializing_present_o |= result_array_q[entry_index].uop.serializing;
        if (latest_writer_vector_q[entry_index]) begin
          rs1_match_vector[entry_index] = query_uop_i.uses_rs1 &&
              query_uop_i.rs1 == result_array_q[entry_index].uop.rd;
          rs2_match_vector[entry_index] = query_uop_i.uses_rs2 &&
              query_uop_i.rs2 == result_array_q[entry_index].uop.rd;
        end
      end
      if (rs1_match_vector[entry_index]) begin
        rs1_index_o  = scoreboard_index_t'(entry_index);
        rs1_source_o = completion_source_array_q[entry_index];
      end
      if (rs2_match_vector[entry_index]) begin
        rs2_index_o  = scoreboard_index_t'(entry_index);
        rs2_source_o = completion_source_array_q[entry_index];
      end
      if (completed_vector_q[entry_index] && !result_array_q[entry_index].uop.exception_valid) begin
        if (rs1_match_vector[entry_index]) begin
          rs1_ready_o = 1'b1;
          rs1_value_o |= result_array_q[entry_index].result;
        end
        if (rs2_match_vector[entry_index]) begin
          rs2_ready_o = 1'b1;
          rs2_value_o |= result_array_q[entry_index].result;
        end
      end
    end
    for (int unsigned port_index = 0; port_index < COMPLETION_PORT_COUNT; port_index++) begin
      if (completion_valid_vector[port_index] && !completion_exception_vector[port_index]) begin
        if (rs1_match_vector[completion_array[port_index].scoreboard_index]) begin
          rs1_ready_o = 1'b1;
          rs1_value_o |= completion_array[port_index].result;
        end
        if (rs2_match_vector[completion_array[port_index].scoreboard_index]) begin
          rs2_ready_o = 1'b1;
          rs2_value_o |= completion_array[port_index].result;
        end
      end
    end
    rs1_pending_o = |rs1_match_vector;
    rs2_pending_o = |rs2_match_vector;
    rs1_ready_o |= !rs1_pending_o;
    rs2_ready_o |= !rs2_pending_o;
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
    (allocate_handshake && !allocate_completed_i) |->
      (allocate_result_i.uop.fu_type inside {FU_LSU, FU_MULDIV}))
  else $error("An ordinary result was allocated without completing");
  assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
    lsu_result_valid_i |->
      (valid_vector_q[lsu_result_i.scoreboard_index] &&
       result_array_q[lsu_result_i.scoreboard_index].uop.mem_ctrl.cmd != MEM_CMD_NONE))
  else $error("LSU completion has no live memory owner");
  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(
      rs1_match_vector
  ) && $onehot0(
      rs2_match_vector
  ))
  else $error("Operand query selected multiple producers");
  for (genvar first = 0; first < ENTRY_COUNT; first++) begin : gen_writer_check
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      latest_writer_vector_q[first] |->
        (valid_vector_q[first] && result_array_q[first].uop.writes_rd &&
         result_array_q[first].uop.rd != '0))
    else $error("Latest writer has no live register destination");
    for (genvar second = first + 1; second < ENTRY_COUNT; second++) begin : gen_pair
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        (latest_writer_vector_q[first] && latest_writer_vector_q[second]) |->
          result_array_q[first].uop.rd != result_array_q[second].uop.rd)
      else $error("Two instructions own the latest value of the same register");
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        (valid_vector_q[first] && !completed_vector_q[first] &&
         valid_vector_q[second] && !completed_vector_q[second]) |->
          !(result_array_q[first].uop.mem_ctrl.cmd != MEM_CMD_NONE &&
            result_array_q[second].uop.mem_ctrl.cmd != MEM_CMD_NONE))
      else $error("Two unfinished memory instructions share the single LSU");
    end
  end
  assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
    allocate_valid_i |-> allocate_ready_o)
  else $error("Issued instruction has no reserved scoreboard entry");
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (commit_result_valid_o && !commit_result_ready_i && !flush_i) |=>
      (flush_i || (commit_result_valid_o && $stable(
      commit_result_o
  ))))
  else $error("Oldest result changed while commit was stalled");
`endif
endmodule
