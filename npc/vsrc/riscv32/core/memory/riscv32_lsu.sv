// LSU执行访存语义、检查自然对齐并格式化load结果。
// AXI4协议转换、cache、MMIO路由和存储系统时序均位于本模块之外。
module riscv32_lsu
  import riscv32_pkg::*;
  // 有效地址经过LSU检查后显式转换为物理地址，避免默认假设XLEN等于PADDR_WIDTH。
  import riscv32_addr_map_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    input  lsu_req_t      lsu_req_i,
    input  logic          lsu_req_valid_i,
    output logic          lsu_req_ready_o,
    output logic          lsu_transaction_active_o,
    output logic          lsu_pending_writes_rd_o,
    output arch_reg_idx_t lsu_pending_rd_o,

    output data_memory_req_t data_memory_req_o,
    output logic             data_memory_req_valid_o,
    input  logic             data_memory_req_ready_i,

    input  data_memory_resp_t data_memory_resp_i,
    input  logic              data_memory_resp_valid_i,
    output logic              data_memory_resp_ready_o,

    output writeback_result_t lsu_writeback_o,
    output logic              lsu_writeback_valid_o,
    input  logic              lsu_writeback_ready_i
);

  // 单个在途上下文：空闲或旧访存成功交付时，普通请求直接进入存储层。
  // 下游不接收时保存请求并重试；本地异常先保存，下一拍从完成口有序返回。
  typedef enum logic [1:0] {
    LSU_IDLE,
    LSU_DISPATCH_REGISTERED_REQUEST,
    LSU_WAIT_MEMORY_RESPONSE
  } lsu_state_e;

  lsu_state_e state_q;
  lsu_state_e state_d;

  // 外部lsu_req_t包含完整译码结果，便于EXU/LSU边界表达一条指令；但访存发出后，
  // LSU只保存完成和提交真正需要的字段。分支预测、ALU操作、CSR控制和源寄存器索引
  // 不参与访存返回，若把整个decoded_uop_t锁存会为每个无关字段生成触发器。
  typedef struct packed {
    program_counter_t pc;
    instruction_t     instruction;
    arch_reg_idx_t    rd;
    logic             writes_rd;
    mem_uop_ctrl_t    mem_ctrl;
    logic             exception_valid;
    exception_cause_e exception_cause;
    xlen_data_t       exception_tval;
    program_counter_t next_pc;
    effective_addr_t  effective_addr;
    xlen_data_t       store_data;
  } pending_lsu_context_t;

  pending_lsu_context_t pending_lsu_context_q;
  lsu_req_t             pending_lsu_req;
  lsu_req_t             active_lsu_req;

  writeback_result_t local_writeback;
  writeback_result_t memory_writeback;

  logic lsu_req_handshake;
  logic data_memory_req_handshake;
  logic data_memory_resp_handshake;

  localparam int unsigned CORE_BYTE_OFFSET_WIDTH = (CORE_DATA_BYTE_COUNT > 1) ? $clog2(
      CORE_DATA_BYTE_COUNT
  ) : 1;

  // store路径属于core存储端口，load格式化结果属于GPR数据域。二者当前同宽只是
  // RV32基线配置，使用不同语义类型后可以独立调整XLEN和存储beat宽度。
  logic       is_load;
  logic       is_store;
  logic       has_memory_access;
  logic       address_misaligned;
  logic       complete_locally;
  core_data_t store_write_data;
  // strobe描述core数据口每个字节通道是否写入，它取决于CORE_DATA_WIDTH，而不是XLEN。
  core_byte_strobe_t store_byte_strobe;
  logic [7:0]        selected_byte;
  logic [15:0]       selected_halfword;
  logic [31:0]       selected_word;
  xlen_data_t        formatted_load_data;

  function automatic logic request_address_misaligned(input lsu_req_t request);
    unique case (request.uop.mem_ctrl.size)
      MEM_SIZE_HALF:   return request.effective_addr[0];
      MEM_SIZE_WORD:   return request.effective_addr[1:0] != 2'b00;
      MEM_SIZE_DOUBLE: return request.effective_addr[2:0] != 3'b000;
      default:         return 1'b0;
    endcase
  endfunction

  function automatic logic request_has_memory_access(input lsu_req_t request);
    return (request.uop.mem_ctrl.cmd == MEM_CMD_LOAD) ||
           (request.uop.mem_ctrl.cmd == MEM_CMD_STORE);
  endfunction

  function automatic core_byte_strobe_t request_store_byte_strobe(input lsu_req_t request);
    logic [CORE_BYTE_OFFSET_WIDTH-1:0] request_byte_offset;
    request_byte_offset = request.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0];
    unique case (request.uop.mem_ctrl.size)
      MEM_SIZE_BYTE:   return core_byte_strobe_t'(1) << request_byte_offset;
      MEM_SIZE_HALF:   return core_byte_strobe_t'(2'b11) << request_byte_offset;
      MEM_SIZE_WORD:   return core_byte_strobe_t'(4'b1111) << request_byte_offset;
      MEM_SIZE_DOUBLE: return '1;
      default:         return '0;
    endcase
  endfunction

  function automatic core_data_t request_store_write_data(input lsu_req_t request);
    logic [CORE_BYTE_OFFSET_WIDTH-1:0] request_byte_offset;
    request_byte_offset = request.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0];
    unique case (request.uop.mem_ctrl.size)
      MEM_SIZE_BYTE:
        return core_data_t'(request.store_data[7:0]) << (request_byte_offset * 8);
      MEM_SIZE_HALF:
        return core_data_t'(request.store_data[15:0]) << (request_byte_offset * 8);
      MEM_SIZE_WORD:
        return core_data_t'(request.store_data[31:0]) << (request_byte_offset * 8);
      MEM_SIZE_DOUBLE: return core_data_t'(request.store_data);
      default:         return '0;
    endcase
  endfunction

  assign lsu_req_handshake = lsu_req_valid_i && lsu_req_ready_o;
  // 该状态只描述已经被LSU接收但尚未完成的存储事务，不从ready反推，因而不会
  // 把当前输入valid重新反馈到流水线允许信号中形成组合环。
  assign lsu_transaction_active_o = state_q != LSU_IDLE;
  // 在途目的寄存器用于 RAW 检查，成功完成时可从返回结果前递。
  assign lsu_pending_writes_rd_o = (state_q != LSU_IDLE) &&
      pending_lsu_context_q.writes_rd;
  assign lsu_pending_rd_o           = pending_lsu_context_q.rd;
  assign data_memory_req_handshake  = data_memory_req_valid_o && data_memory_req_ready_i;
  assign data_memory_resp_handshake = data_memory_resp_valid_i && data_memory_resp_ready_o;

  // 先重建旧上下文，再选择入口直通请求；完成数据始终只读取旧上下文。
  always_comb begin
    pending_lsu_req                     = '0;
    pending_lsu_req.uop.pc              = pending_lsu_context_q.pc;
    pending_lsu_req.uop.instruction     = pending_lsu_context_q.instruction;
    pending_lsu_req.uop.rd              = pending_lsu_context_q.rd;
    pending_lsu_req.uop.writes_rd       = pending_lsu_context_q.writes_rd;
    pending_lsu_req.uop.mem_ctrl        = pending_lsu_context_q.mem_ctrl;
    pending_lsu_req.uop.exception_valid = pending_lsu_context_q.exception_valid;
    pending_lsu_req.uop.exception_cause = pending_lsu_context_q.exception_cause;
    pending_lsu_req.uop.exception_tval  = pending_lsu_context_q.exception_tval;
    pending_lsu_req.next_pc             = pending_lsu_context_q.next_pc;
    pending_lsu_req.effective_addr      = pending_lsu_context_q.effective_addr;
    pending_lsu_req.store_data          = pending_lsu_context_q.store_data;
  end

  always_comb begin
    // 只有重试状态需要旧请求。等待响应时可预先计算入口数据，valid 单独阻止发出；
    // 不让旧响应的完成/错误条件先经过 payload mux，再进入地址与字节选择。
    active_lsu_req = (state_q == LSU_DISPATCH_REGISTERED_REQUEST) ?
        pending_lsu_req : lsu_req_i;

    is_load           = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
    is_store          = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_STORE;
    has_memory_access = is_load || is_store;

    address_misaligned = has_memory_access && request_address_misaligned(active_lsu_req);
    complete_locally   = active_lsu_req.uop.exception_valid ||
        address_misaligned || !has_memory_access;

    // strobe只覆盖本条store写入的字节。WORD不能使用'1，否则64位存储口会误写8字节。
    store_write_data  = request_store_write_data(active_lsu_req);
    store_byte_strobe = request_store_byte_strobe(active_lsu_req);
  end

  // 本地请求保留字节地址和访问宽度。协议adapter负责把size翻译成AXI4 AxSIZE，
  // 并保证单次uncached访问使用LEN=0、LAST=1和稳定的transaction ID。
  // 当前无 MMU；RV32 地址保持原值，RV64 地址在这里截取低 32 位作为物理地址。
  always_comb begin
    data_memory_req_o                = '0;
    data_memory_req_o.addr           = phys_addr_t'(active_lsu_req.effective_addr);
    data_memory_req_o.cmd            = active_lsu_req.uop.mem_ctrl.cmd;
    data_memory_req_o.size           = active_lsu_req.uop.mem_ctrl.size;
    data_memory_req_o.write_data     = is_store ? store_write_data : '0;
    data_memory_req_o.byte_strobe    = is_store ? store_byte_strobe : '0;
    data_memory_req_o.transaction_id = '0;
  end

  // 存储层返回完整数据字。LSU根据原始地址低位选择byte/halfword并完成符号扩展。
  // RV64下LW将bit 31符号扩展，LWU零扩展；不能把总线返回宽度直接当作load结果宽度。
  always_comb begin
    selected_byte = 8'(data_memory_resp_i.read_data >>
        (pending_lsu_context_q.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0] * 8));
    selected_halfword = 16'(data_memory_resp_i.read_data >>
        (pending_lsu_context_q.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0] * 8));
    selected_word = 32'(data_memory_resp_i.read_data >>
        (pending_lsu_context_q.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0] * 8));
    formatted_load_data = '0;

    unique case (pending_lsu_context_q.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        formatted_load_data = pending_lsu_context_q.mem_ctrl.unsigned_load
            ? {{(XLEN-8){1'b0}}, selected_byte}
            : {{(XLEN-8){selected_byte[7]}}, selected_byte};
      end
      MEM_SIZE_HALF: begin
        formatted_load_data = pending_lsu_context_q.mem_ctrl.unsigned_load
            ? {{(XLEN-16){1'b0}}, selected_halfword}
            : {{(XLEN-16){selected_halfword[15]}}, selected_halfword};
      end
      MEM_SIZE_WORD: begin
        formatted_load_data = pending_lsu_context_q.mem_ctrl.unsigned_load
            ? xlen_data_t'(selected_word)
            : {{(XLEN-32){selected_word[31]}}, selected_word};
      end
      MEM_SIZE_DOUBLE: begin
        // LD只在RV64中合法。显式转换保留参数化RV32构建，不在共享RTL中引用固定64位切片。
        formatted_load_data = xlen_data_t'(data_memory_resp_i.read_data);
      end
      default: ;
    endcase
  end

  // 已有异常、未对齐访问和非访存操作不进入存储层。
  always_comb begin
    local_writeback              = '0;
    local_writeback.uop          = active_lsu_req.uop;
    local_writeback.next_pc      = active_lsu_req.next_pc;
    local_writeback.memory_addr  = active_lsu_req.effective_addr;
    local_writeback.memory_wdata = is_store ? store_write_data : '0;
    local_writeback.memory_wmask = is_store ? store_byte_strobe : '0;

    if (!active_lsu_req.uop.exception_valid && address_misaligned) begin
      local_writeback.uop.exception_valid = 1'b1;
      local_writeback.uop.exception_cause = is_load
          ? EXC_LOAD_ADDR_MISALIGNED : EXC_STORE_ADDR_MISALIGNED;
      local_writeback.uop.exception_tval = active_lsu_req.effective_addr;
    end

    // 无论异常最初来自IFU、IDU还是本级对齐检查，异常完成包都不得保留正常执行副作用。
    // 统一在LSU出口归一化，避免每个异常产生点分别依赖writes_rd和memory_wmask的初值。
    if (local_writeback.uop.exception_valid) begin
      local_writeback.uop.writes_rd = 1'b0;
      local_writeback.result        = '0;
      local_writeback.memory_wmask  = '0;
    end
  end

  // access_fault来自D-cache、uncached adapter或系统互联，LSU在这里转换成架构异常。
  always_comb begin
    memory_writeback                 = '0;
    memory_writeback.uop.pc          = pending_lsu_context_q.pc;
    memory_writeback.uop.instruction = pending_lsu_context_q.instruction;
    memory_writeback.uop.rd          = pending_lsu_context_q.rd;
    memory_writeback.uop.writes_rd   = pending_lsu_context_q.writes_rd;
    memory_writeback.uop.mem_ctrl    = pending_lsu_context_q.mem_ctrl;
    memory_writeback.result          =
        (pending_lsu_context_q.mem_ctrl.cmd == MEM_CMD_LOAD) ? formatted_load_data : '0;
    memory_writeback.next_pc         = pending_lsu_context_q.next_pc;
    memory_writeback.memory_addr     = pending_lsu_context_q.effective_addr;
    memory_writeback.memory_rdata    =
        (pending_lsu_context_q.mem_ctrl.cmd == MEM_CMD_LOAD) ? core_data_t'(formatted_load_data) : '0;
    memory_writeback.memory_wdata    =
        (pending_lsu_context_q.mem_ctrl.cmd == MEM_CMD_STORE) ? request_store_write_data(pending_lsu_req) : '0;
    memory_writeback.memory_wmask    =
        (pending_lsu_context_q.mem_ctrl.cmd == MEM_CMD_STORE) ? request_store_byte_strobe(pending_lsu_req) : '0;

    if (data_memory_resp_i.access_fault) begin
      memory_writeback.uop.exception_valid = 1'b1;
      memory_writeback.uop.exception_cause = (pending_lsu_context_q.mem_ctrl.cmd == MEM_CMD_LOAD)
          ? EXC_LOAD_ACCESS_FAULT : EXC_STORE_ACCESS_FAULT;
      memory_writeback.uop.exception_tval = pending_lsu_context_q.effective_addr;
      memory_writeback.uop.writes_rd      = 1'b0;
      memory_writeback.result             = '0;
      memory_writeback.memory_rdata       = '0;
    end
  end

  // 第一段：旧响应交付与新请求发出分别计算，避免新 payload 改变旧 completion。
  assign lsu_req_ready_o = (state_q == LSU_IDLE) ||
      ((state_q == LSU_WAIT_MEMORY_RESPONSE) && data_memory_resp_valid_i &&
       lsu_writeback_ready_i && !data_memory_resp_i.access_fault);
  assign data_memory_req_valid_o = !complete_locally &&
      ((state_q == LSU_DISPATCH_REGISTERED_REQUEST) ||
       (lsu_req_ready_o && lsu_req_valid_i));

  always_comb begin
    data_memory_resp_ready_o = 1'b0;
    lsu_writeback_o          = '0;
    lsu_writeback_valid_o    = 1'b0;

    unique case (state_q)
      LSU_DISPATCH_REGISTERED_REQUEST: begin
        if (complete_locally) begin
          lsu_writeback_o       = local_writeback;
          lsu_writeback_valid_o = 1'b1;
        end
      end

      LSU_WAIT_MEMORY_RESPONSE: begin
        data_memory_resp_ready_o = lsu_writeback_ready_i;
        lsu_writeback_o          = memory_writeback;
        lsu_writeback_valid_o    = data_memory_resp_valid_i;
      end

      default: ;
    endcase
  end

  // 第二段：状态转移逻辑。每个本地request只产生一个本地response；
  // AXI4的AR/R或AW/W/B细分事务不能泄漏到本状态机中。
  always_comb begin
    state_d = state_q;

    unique case (state_q)
      LSU_IDLE: begin
        if (lsu_req_handshake) begin
          state_d = LSU_DISPATCH_REGISTERED_REQUEST;
        end
      end

      LSU_DISPATCH_REGISTERED_REQUEST: begin
        if (complete_locally && lsu_writeback_ready_i) begin
          state_d = LSU_IDLE;
        end else if (!complete_locally && data_memory_req_handshake) begin
          state_d = LSU_WAIT_MEMORY_RESPONSE;
        end
      end

      LSU_WAIT_MEMORY_RESPONSE: begin
        if (data_memory_resp_handshake) begin
          state_d = LSU_IDLE;
        end
      end

      default: begin
        state_d = LSU_IDLE;
      end
    endcase
    if (lsu_req_handshake) begin
      state_d = data_memory_req_handshake ?
          LSU_WAIT_MEMORY_RESPONSE : LSU_DISPATCH_REGISTERED_REQUEST;
    end
  end

  // 第三段：状态和紧凑请求上下文分组更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      state_q <= LSU_IDLE;
    else
      state_q <= state_d;
  end

  // pending payload不复位。state_q=IDLE时它没有语义；每次入口握手都覆盖，包括需要
  // 本地完成的异常请求；旧完成与新请求交接时只在沿后切换上下文。
  always_ff @(posedge clk_i) begin
    if (lsu_req_handshake) begin
      pending_lsu_context_q.pc              <= lsu_req_i.uop.pc;
      pending_lsu_context_q.instruction     <= lsu_req_i.uop.instruction;
      pending_lsu_context_q.rd              <= lsu_req_i.uop.rd;
      pending_lsu_context_q.writes_rd       <= lsu_req_i.uop.writes_rd;
      pending_lsu_context_q.mem_ctrl        <= lsu_req_i.uop.mem_ctrl;
      pending_lsu_context_q.exception_valid <= lsu_req_i.uop.exception_valid;
      pending_lsu_context_q.exception_cause <= lsu_req_i.uop.exception_cause;
      pending_lsu_context_q.exception_tval  <= lsu_req_i.uop.exception_tval;
      pending_lsu_context_q.next_pc         <= lsu_req_i.next_pc;
      pending_lsu_context_q.effective_addr  <= lsu_req_i.effective_addr;
      pending_lsu_context_q.store_data      <= lsu_req_i.store_data;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  a_preexisting_exception_never_reaches_memory :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == LSU_DISPATCH_REGISTERED_REQUEST &&
     pending_lsu_context_q.exception_valid)
    |-> !data_memory_req_valid_o)
  else
    $error("LSU issued a memory request for an instruction with an older exception");

  a_misaligned_access_never_reaches_memory :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == LSU_DISPATCH_REGISTERED_REQUEST && address_misaligned)
    |-> !data_memory_req_valid_o)
  else
    $error("LSU issued a memory request for a misaligned access");

  a_exception_writeback_has_no_register_write :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lsu_writeback_valid_o && lsu_writeback_o.uop.exception_valid)
    |-> !lsu_writeback_o.uop.writes_rd)
  else
    $error("LSU exception retained a destination-register side effect");

  a_fault_response_blocks_rollover :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == LSU_WAIT_MEMORY_RESPONSE && data_memory_resp_valid_i &&
     data_memory_resp_i.access_fault) |-> !lsu_req_ready_o)
  else $error("LSU accepted a younger request while returning a fault");

  a_direct_request_is_remembered :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lsu_req_handshake && data_memory_req_handshake)
    |=> state_q == LSU_WAIT_MEMORY_RESPONSE)
  else $error("LSU lost a directly dispatched request");

  a_dispatch_has_one_completion_route :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == LSU_DISPATCH_REGISTERED_REQUEST)
    |-> !(data_memory_req_valid_o && lsu_writeback_valid_o))
  else
    $error("LSU dispatched one request to memory and local writeback simultaneously");

  a_memory_request_stable_while_backpressured :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (data_memory_req_valid_o && !data_memory_req_ready_i)
    |=> $stable(data_memory_req_o))
  else
    $error("LSU memory request changed while the storage subsystem applied backpressure");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
