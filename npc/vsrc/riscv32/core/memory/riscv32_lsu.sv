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
    output mem_txn_id_t    lsu_req_id_o,
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
    output mem_txn_id_t        lsu_writeback_id_o,
    output logic              lsu_writeback_valid_o,
    input  logic              lsu_writeback_ready_i
);

  // 每个槽位只保存访存完成所需字段。槽位从接收到响应交付始终保持身份；
  // 分支取消由后端标记，LSU 继续排空，不能提前复用给迟到响应。
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


  typedef enum logic [1:0] {LSU_FREE, LSU_REQUEST, LSU_RESPONSE, LSU_LOCAL} lsu_state_e;
  localparam int unsigned SLOT_W = (LSU_ENTRIES > 1) ? $clog2(LSU_ENTRIES) : 1;
  typedef logic [SLOT_W-1:0] slot_index_t;
  localparam int unsigned CORE_BYTE_OFFSET_WIDTH = (CORE_DATA_BYTE_COUNT > 1) ?
      $clog2(CORE_DATA_BYTE_COUNT) : 1;

  lsu_state_e state_q[LSU_ENTRIES], state_d[LSU_ENTRIES];
  pending_lsu_context_t context_array_q[LSU_ENTRIES], response_context;
  slot_index_t allocate_index, request_index, response_index, local_index;
  slot_index_t held_request_index_q, held_local_index_q;
  logic request_held_q, memory_response_held_q, local_response_held_q;
  logic free_present, queued_request_present, local_present, select_memory_response;
  logic lsu_req_handshake, data_memory_req_handshake, data_memory_resp_handshake;
  logic writeback_handshake, input_completes_locally;
  lsu_req_t active_lsu_req, local_lsu_req;
  writeback_result_t local_writeback, memory_writeback;
  logic is_store, complete_locally, local_is_store, local_is_load, local_address_misaligned;
  core_data_t store_write_data, local_store_write_data, shifted_load_data;
  core_byte_strobe_t store_byte_strobe, local_store_byte_strobe;
  logic [7:0] selected_byte;
  logic [15:0] selected_halfword;
  logic [31:0] selected_word;
  xlen_data_t formatted_load_data;

  function automatic logic request_address_misaligned(input lsu_req_t request);
    unique case (request.uop.mem_ctrl.size)
      MEM_SIZE_HALF:   return request.effective_addr[0];
      MEM_SIZE_WORD:   return request.effective_addr[1:0] != 2'b00;
      MEM_SIZE_DOUBLE: return request.effective_addr[2:0] != 3'b000;
      default:         return 1'b0;
    endcase
  endfunction

  function automatic core_byte_strobe_t request_store_byte_strobe(input effective_addr_t addr,
                                                                  input mem_size_e size);
    logic [CORE_BYTE_OFFSET_WIDTH-1:0] request_byte_offset;
    request_byte_offset = addr[CORE_BYTE_OFFSET_WIDTH-1:0];
    unique case (size)
      MEM_SIZE_BYTE:   return core_byte_strobe_t'(1) << request_byte_offset;
      MEM_SIZE_HALF:   return core_byte_strobe_t'(2'b11) << request_byte_offset;
      MEM_SIZE_WORD:   return core_byte_strobe_t'(4'b1111) << request_byte_offset;
      MEM_SIZE_DOUBLE: return '1;
      default:         return '0;
    endcase
  endfunction

  function automatic core_data_t request_store_write_data(
      input effective_addr_t addr, input mem_size_e size, input xlen_data_t store_data);
    logic [CORE_BYTE_OFFSET_WIDTH-1:0] request_byte_offset;
    request_byte_offset = addr[CORE_BYTE_OFFSET_WIDTH-1:0];
    unique case (size)
      MEM_SIZE_BYTE:   return core_data_t'(store_data[7:0]) << (request_byte_offset * 8);
      MEM_SIZE_HALF:   return core_data_t'(store_data[15:0]) << (request_byte_offset * 8);
      MEM_SIZE_WORD:   return core_data_t'(store_data[31:0]) << (request_byte_offset * 8);
      MEM_SIZE_DOUBLE: return core_data_t'(store_data);
      default:         return '0;
    endcase
  endfunction


  function automatic pending_lsu_context_t compact_request(input lsu_req_t request);
    return '{pc: request.uop.pc, instruction: request.uop.instruction,
             rd: request.uop.rd, writes_rd: request.uop.writes_rd,
             mem_ctrl: request.uop.mem_ctrl, exception_valid: request.uop.exception_valid,
             exception_cause: request.uop.exception_cause, exception_tval: request.uop.exception_tval,
             next_pc: request.next_pc, effective_addr: request.effective_addr,
             store_data: request.store_data};
  endfunction

  function automatic lsu_req_t expand_context(input pending_lsu_context_t context_value);
    lsu_req_t request;
    request = '0;
    request.uop.pc = context_value.pc;
    request.uop.instruction = context_value.instruction;
    request.uop.rd = context_value.rd;
    request.uop.writes_rd = context_value.writes_rd;
    request.uop.mem_ctrl = context_value.mem_ctrl;
    request.uop.exception_valid = context_value.exception_valid;
    request.uop.exception_cause = context_value.exception_cause;
    request.uop.exception_tval = context_value.exception_tval;
    request.next_pc = context_value.next_pc;
    request.effective_addr = context_value.effective_addr;
    request.store_data = context_value.store_data;
    return request;
  endfunction

  function automatic logic completes_locally(input lsu_req_t request);
    return request.uop.exception_valid || request_address_misaligned(request) ||
        !(request.uop.mem_ctrl.cmd inside {MEM_CMD_LOAD, MEM_CMD_STORE});
  endfunction

  // 1. 槽位分配和完成身份。成功的存储响应当拍释放槽位，可以接收下一请求。
  // 本地异常不做同拍复用；故障返回当拍也不接收新的年轻请求。
  assign response_index = slot_index_t'(data_memory_resp_i.transaction_id);
  assign response_context = context_array_q[response_index];
  assign lsu_req_id_o = mem_txn_id_t'(allocate_index);
  assign lsu_writeback_id_o = select_memory_response ?
      mem_txn_id_t'(response_index) : mem_txn_id_t'(local_index);
  assign lsu_req_handshake = lsu_req_valid_i && lsu_req_ready_o;
  assign data_memory_req_handshake = data_memory_req_valid_o && data_memory_req_ready_i;
  assign data_memory_resp_handshake = data_memory_resp_valid_i && data_memory_resp_ready_o;
  assign writeback_handshake = lsu_writeback_valid_o && lsu_writeback_ready_i;
  assign input_completes_locally = completes_locally(lsu_req_i);

  always_comb begin
    free_present = 1'b0;
    allocate_index = '0;
    for (int slot = LSU_ENTRIES - 1; slot >= 0; slot--) begin
      if (state_q[slot] == LSU_FREE ||
          (data_memory_resp_handshake && !data_memory_resp_i.access_fault &&
           response_index == slot_index_t'(slot))) begin
        free_present = 1'b1;
        allocate_index = slot_index_t'(slot);
      end
    end
  end
  always_comb begin
    queued_request_present = 1'b0;
    request_index = '0;
    local_present = 1'b0;
    local_index = '0;
    lsu_transaction_active_o = 1'b0;
    for (int slot = LSU_ENTRIES - 1; slot >= 0; slot--) begin
      if (state_q[slot] != LSU_FREE) lsu_transaction_active_o = 1'b1;
      if (state_q[slot] == LSU_REQUEST) begin
        queued_request_present = 1'b1;
        request_index = slot_index_t'(slot);
      end
      if (state_q[slot] == LSU_LOCAL) begin
        local_present = 1'b1;
        local_index = slot_index_t'(slot);
      end
    end
    if (request_held_q) request_index = held_request_index_q;
    if (local_response_held_q) local_index = held_local_index_q;
  end
  // 单槽空闲时直接接收，不把无关的响应错误判断串进入口允许路径。
  assign lsu_req_ready_o = (LSU_ENTRIES == 1) ?
      ((state_q[0] == LSU_FREE) ||
       ((state_q[0] == LSU_RESPONSE) && data_memory_resp_valid_i &&
        lsu_writeback_ready_i && !data_memory_resp_i.access_fault)) :
      (free_present && !(data_memory_resp_valid_i && data_memory_resp_i.access_fault));
  // 顺序后端仅使用单槽配置；ROB 后端按各自条目做依赖检查。
  assign lsu_pending_writes_rd_o = state_q[0] != LSU_FREE && context_array_q[0].writes_rd;
  assign lsu_pending_rd_o = context_array_q[0].rd;

  // 2. 已排队请求优先，否则入口直接送存储层。受阻时只保存原请求，不增加固定拍。
  assign active_lsu_req = queued_request_present ?
      expand_context(context_array_q[request_index]) : lsu_req_i;
  assign complete_locally = completes_locally(active_lsu_req);
  assign is_store = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_STORE;
  assign store_write_data = request_store_write_data(active_lsu_req.effective_addr,
      active_lsu_req.uop.mem_ctrl.size, active_lsu_req.store_data);
  assign store_byte_strobe = request_store_byte_strobe(active_lsu_req.effective_addr,
      active_lsu_req.uop.mem_ctrl.size);
  always_comb begin
    data_memory_req_o = '0;
    data_memory_req_o.addr = phys_addr_t'(active_lsu_req.effective_addr);
    data_memory_req_o.cmd = active_lsu_req.uop.mem_ctrl.cmd;
    data_memory_req_o.size = active_lsu_req.uop.mem_ctrl.size;
    data_memory_req_o.write_data = is_store ? store_write_data : '0;
    data_memory_req_o.byte_strobe = is_store ? store_byte_strobe : '0;
    data_memory_req_o.transaction_id = queued_request_present ?
        mem_txn_id_t'(request_index) : mem_txn_id_t'(allocate_index);
  end
  assign data_memory_req_valid_o = !complete_locally &&
      (queued_request_present || lsu_req_handshake);

  // 3. 本地异常优先，其余时间预先选择存储上下文，不等 RVALID 再切换宽数据。
  // 已展示且受阻的存储响应优先级更高；本地异常的有效状态本身保持其选择。
  assign select_memory_response = (LSU_ENTRIES == 1) ?
      (state_q[0] == LSU_RESPONSE) : (!local_present || memory_response_held_q);
  assign local_lsu_req = expand_context(context_array_q[local_index]);
  assign local_is_store = local_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_STORE;
  assign local_is_load = local_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
  assign local_address_misaligned = (local_is_load || local_is_store) &&
      request_address_misaligned(local_lsu_req);
  assign local_store_write_data = request_store_write_data(local_lsu_req.effective_addr,
      local_lsu_req.uop.mem_ctrl.size, local_lsu_req.store_data);
  assign local_store_byte_strobe = request_store_byte_strobe(local_lsu_req.effective_addr,
      local_lsu_req.uop.mem_ctrl.size);
  assign lsu_writeback_o = select_memory_response ? memory_writeback : local_writeback;
  assign lsu_writeback_valid_o = select_memory_response ? data_memory_resp_valid_i : local_present;
  assign data_memory_resp_ready_o = select_memory_response && lsu_writeback_ready_i;

  // 存储层返回完整数据字。LSU根据原始地址低位选择byte/halfword并完成符号扩展。
  // RV64下LW将bit 31符号扩展，LWU零扩展；不能把总线返回宽度直接当作load结果宽度。
  always_comb begin
    shifted_load_data = data_memory_resp_i.read_data >>
        (response_context.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0] * 8);
    selected_byte       = 8'(shifted_load_data);
    selected_halfword   = 16'(shifted_load_data);
    selected_word       = 32'(shifted_load_data);
    formatted_load_data = '0;

    unique case (response_context.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        formatted_load_data = response_context.mem_ctrl.unsigned_load
            ? {{(XLEN-8){1'b0}}, selected_byte}
            : {{(XLEN-8){selected_byte[7]}}, selected_byte};
      end
      MEM_SIZE_HALF: begin
        formatted_load_data = response_context.mem_ctrl.unsigned_load
            ? {{(XLEN-16){1'b0}}, selected_halfword}
            : {{(XLEN-16){selected_halfword[15]}}, selected_halfword};
      end
      MEM_SIZE_WORD: begin
        formatted_load_data = response_context.mem_ctrl.unsigned_load
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
    local_writeback.uop          = local_lsu_req.uop;
    local_writeback.next_pc      = local_lsu_req.next_pc;
    local_writeback.memory_addr  = local_lsu_req.effective_addr;
    local_writeback.memory_wdata = local_is_store ? local_store_write_data : '0;
    local_writeback.memory_wmask = local_is_store ? local_store_byte_strobe : '0;

    if (!local_lsu_req.uop.exception_valid && local_address_misaligned) begin
      local_writeback.uop.exception_valid = 1'b1;
      local_writeback.uop.exception_cause = local_is_load
          ? EXC_LOAD_ADDR_MISALIGNED : EXC_STORE_ADDR_MISALIGNED;
      local_writeback.uop.exception_tval = local_lsu_req.effective_addr;
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
    memory_writeback.uop.pc          = response_context.pc;
    memory_writeback.uop.instruction = response_context.instruction;
    memory_writeback.uop.rd          = response_context.rd;
    memory_writeback.uop.writes_rd   = response_context.writes_rd;
    memory_writeback.uop.mem_ctrl    = response_context.mem_ctrl;
    memory_writeback.result          =
        (response_context.mem_ctrl.cmd == MEM_CMD_LOAD) ? formatted_load_data : '0;
    memory_writeback.next_pc      = response_context.next_pc;
    memory_writeback.memory_addr  = response_context.effective_addr;
    memory_writeback.memory_rdata =
        (response_context.mem_ctrl.cmd == MEM_CMD_LOAD) ? core_data_t'(formatted_load_data) : '0;
    memory_writeback.memory_wdata =
        (response_context.mem_ctrl.cmd == MEM_CMD_STORE) ?
            request_store_write_data(response_context.effective_addr,
                                     response_context.mem_ctrl.size,
                                     response_context.store_data) : '0;
    memory_writeback.memory_wmask =
        (response_context.mem_ctrl.cmd == MEM_CMD_STORE) ?
            request_store_byte_strobe(response_context.effective_addr,
                                      response_context.mem_ctrl.size) : '0;

    if (data_memory_resp_i.access_fault) begin
      memory_writeback.uop.exception_valid = 1'b1;
      memory_writeback.uop.exception_cause = (response_context.mem_ctrl.cmd == MEM_CMD_LOAD)
          ? EXC_LOAD_ACCESS_FAULT : EXC_STORE_ACCESS_FAULT;
      memory_writeback.uop.exception_tval = response_context.effective_addr;
      memory_writeback.uop.writes_rd      = 1'b0;
      memory_writeback.result             = '0;
      memory_writeback.memory_rdata       = '0;
    end
  end


  // 4. 每槽状态转移。完成释放在前，新分配在后，定义同拍复用的优先级。
  always_comb begin
    for (int slot = 0; slot < LSU_ENTRIES; slot++) state_d[slot] = state_q[slot];
    if (writeback_handshake)
      state_d[slot_index_t'(lsu_writeback_id_o)] = LSU_FREE;
    if (data_memory_req_handshake && queued_request_present)
      state_d[request_index] = LSU_RESPONSE;
    if (lsu_req_handshake) begin
      if (input_completes_locally) state_d[allocate_index] = LSU_LOCAL;
      else if (!queued_request_present && data_memory_req_handshake)
        state_d[allocate_index] = LSU_RESPONSE;
      else state_d[allocate_index] = LSU_REQUEST;
    end
  end

  // 5. 状态与载荷寄存器。无效槽位的载荷不复位。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int slot = 0; slot < LSU_ENTRIES; slot++) state_q[slot] <= LSU_FREE;
      request_held_q <= 1'b0;
      memory_response_held_q <= 1'b0;
      local_response_held_q <= 1'b0;
    end else begin
      for (int slot = 0; slot < LSU_ENTRIES; slot++) state_q[slot] <= state_d[slot];
      request_held_q <= data_memory_req_valid_o && !data_memory_req_ready_i;
      memory_response_held_q <= lsu_writeback_valid_o && !lsu_writeback_ready_i && select_memory_response;
      local_response_held_q <= local_present && !lsu_writeback_ready_i && !select_memory_response;
    end
  end
  always_ff @(posedge clk_i) begin
    if (lsu_req_handshake) context_array_q[allocate_index] <= compact_request(lsu_req_i);
    if (data_memory_req_valid_o && !data_memory_req_ready_i)
      held_request_index_q <= slot_index_t'(data_memory_req_o.transaction_id);
    if (local_present && !select_memory_response && !lsu_writeback_ready_i)
      held_local_index_q <= local_index;
  end

`ifndef SYNTHESIS
  initial assert (LSU_ENTRIES inside {1, 2} && LSU_ENTRIES <= MEM_TXN_COUNT);
  a_memory_response_has_owner: assert property (@(posedge clk_i) disable iff (!rst_ni)
    data_memory_resp_valid_i |-> int'(data_memory_resp_i.transaction_id) < LSU_ENTRIES &&
      state_q[response_index] == LSU_RESPONSE);
  a_preexisting_exception_never_reaches_memory: assert property (@(posedge clk_i) disable iff (!rst_ni)
    data_memory_req_valid_o |-> !active_lsu_req.uop.exception_valid);
  a_misaligned_access_never_reaches_memory: assert property (@(posedge clk_i) disable iff (!rst_ni)
    data_memory_req_valid_o |-> !request_address_misaligned(active_lsu_req));
  a_exception_writeback_has_no_register_write: assert property (@(posedge clk_i) disable iff (!rst_ni)
    lsu_writeback_valid_o && lsu_writeback_o.uop.exception_valid |-> !lsu_writeback_o.uop.writes_rd);
  a_fault_response_blocks_rollover: assert property (@(posedge clk_i) disable iff (!rst_ni)
    data_memory_resp_valid_i && data_memory_resp_i.access_fault |-> !lsu_req_ready_o);
  a_direct_request_is_remembered: assert property (@(posedge clk_i) disable iff (!rst_ni)
    data_memory_req_handshake |=> state_q[slot_index_t'($past(data_memory_req_o.transaction_id))] == LSU_RESPONSE);
  a_memory_request_stable_while_backpressured: assert property (@(posedge clk_i) disable iff (!rst_ni)
    data_memory_req_valid_o && !data_memory_req_ready_i |=>
      data_memory_req_valid_o && $stable(data_memory_req_o));
  a_writeback_stable_while_backpressured: assert property (@(posedge clk_i) disable iff (!rst_ni)
    lsu_writeback_valid_o && !lsu_writeback_ready_i |=>
      lsu_writeback_valid_o && $stable(lsu_writeback_o) && $stable(lsu_writeback_id_o));
`endif
endmodule
