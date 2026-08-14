// LSU执行访存语义、检查自然对齐并格式化load结果。
// AXI4协议转换、cache、MMIO路由和存储系统时序均位于本模块之外。
module riscv32_lsu
  import riscv32_pkg::*;
  // 有效地址经过LSU检查后显式转换为物理地址，避免默认假设XLEN等于PADDR_WIDTH。
  import riscv32_addr_map_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  lsu_req_t lsu_req_i,
    input  logic     lsu_req_valid_i,
    output logic     lsu_req_ready_o,

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

  // 当前实现是阻塞式LSU：一个请求被存储层接收后，必须等到对应response返回。
  // 这个边界后续可以接uncached AXI4 manager，也可以替换为D-cache。乱序版本应在
  // LSU前增加load queue/store queue，并用transaction_id关联返回结果。
  typedef enum logic [1:0] {
    LSU_IDLE,
    LSU_SEND_MEMORY_REQUEST,
    LSU_WAIT_MEMORY_RESPONSE,
    LSU_HOLD_WRITEBACK
  } lsu_state_e;

  lsu_state_e state_q;
  lsu_state_e state_d;

  lsu_req_t lsu_req_q;
  lsu_req_t lsu_req_d;
  lsu_req_t active_lsu_req;

  writeback_result_t buffered_writeback_q;
  writeback_result_t buffered_writeback_d;
  writeback_result_t local_writeback;
  writeback_result_t memory_writeback;

  logic lsu_req_handshake;
  logic data_memory_req_handshake;
  logic data_memory_resp_handshake;
  logic lsu_writeback_handshake;

  localparam int unsigned CORE_BYTE_OFFSET_WIDTH =
      (CORE_DATA_BYTE_COUNT > 1) ? $clog2(CORE_DATA_BYTE_COUNT) : 1;

  // store路径属于core存储端口，load格式化结果属于GPR数据域。二者当前同宽只是
  // RV32基线配置，使用不同语义类型后可以独立调整XLEN和存储beat宽度。
  logic                   is_load;
  logic                   is_store;
  logic                   has_memory_access;
  logic                   is_halfword_access;
  logic                   is_word_access;
  logic                   address_misaligned;
  logic                   complete_locally;
  logic [CORE_BYTE_OFFSET_WIDTH-1:0] byte_offset;
  core_data_t                          store_write_data;
  // strobe描述core数据口每个字节通道是否写入，它取决于CORE_DATA_WIDTH，而不是XLEN。
  core_byte_strobe_t                   store_byte_strobe;
  logic [7:0]                          selected_byte;
  logic [15:0]                         selected_halfword;
  logic [31:0]                         selected_word;
  xlen_data_t                          formatted_load_data;

  assign lsu_req_handshake = lsu_req_valid_i && lsu_req_ready_o;
  assign data_memory_req_handshake =
      data_memory_req_valid_o && data_memory_req_ready_i;
  assign data_memory_resp_handshake =
      data_memory_resp_valid_i && data_memory_resp_ready_o;
  assign lsu_writeback_handshake = lsu_writeback_valid_o && lsu_writeback_ready_i;

  // IDLE时可以直接使用输入实现零额外入口延迟；请求被接受后只读取锁存副本。
  // byte_offset按core beat宽度选择字节通道；自然对齐仍按ISA访问大小判断：
  // half只检查bit 0，word检查bits[1:0]。
  // 不要用总线beat宽度替代ISA对齐规则；总线即使是64位，LW仍只要求4字节对齐。
  always_comb begin
    active_lsu_req = (state_q == LSU_IDLE) ? lsu_req_i : lsu_req_q;

    byte_offset = active_lsu_req.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0];
    is_load            = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
    is_store           = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_STORE;
    has_memory_access  = is_load || is_store;
    is_halfword_access = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_HALF;
    is_word_access     = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_WORD;

    address_misaligned = has_memory_access &&
                         ((is_halfword_access && byte_offset[0]) ||
                          (is_word_access &&
                           (active_lsu_req.effective_addr[1:0] != 2'b00)));
    complete_locally = active_lsu_req.uop.exception_valid ||
                       address_misaligned || !has_memory_access;

    // strobe只覆盖本条store写入的字节。WORD不能使用'1，否则64位存储口会误写8字节。
    store_write_data  = '0;
    store_byte_strobe = '0;
    unique case (active_lsu_req.uop.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        store_byte_strobe = core_byte_strobe_t'(1) << byte_offset;
        store_write_data = core_data_t'(active_lsu_req.store_data[7:0])
                           << (byte_offset * 8);
      end
      MEM_SIZE_HALF: begin
        store_byte_strobe = core_byte_strobe_t'(2'b11) << byte_offset;
        store_write_data = core_data_t'(active_lsu_req.store_data[15:0])
                           << (byte_offset * 8);
      end
      MEM_SIZE_WORD: begin
        store_byte_strobe = core_byte_strobe_t'(4'b1111) << byte_offset;
        store_write_data = core_data_t'(active_lsu_req.store_data[31:0])
                           << (byte_offset * 8);
      end
      default: ;
    endcase
  end

  // 本地请求保留字节地址和访问宽度。协议adapter负责把size翻译成AXI4 AxSIZE，
  // 并保证单次uncached访问使用LEN=0、LAST=1和稳定的transaction ID。
  // 当前无MMU，effective address在边界处显式恒等转换为physical address。
  // 未来加入地址翻译时只替换该路径，不需要改写LSU访存语义或下游协议adapter。
  always_comb begin
    data_memory_req_o                = '0;
    data_memory_req_o.addr           = phys_addr_t'(active_lsu_req.effective_addr);
    data_memory_req_o.cmd            = active_lsu_req.uop.mem_ctrl.cmd;
    data_memory_req_o.size           = active_lsu_req.uop.mem_ctrl.size;
    data_memory_req_o.write_data     = store_write_data;
    data_memory_req_o.byte_strobe    = store_byte_strobe;
    data_memory_req_o.transaction_id = '0;
  end

  // 存储层返回完整数据字。LSU根据原始地址低位选择byte/halfword并完成符号扩展。
  // RV64下LW将bit 31符号扩展，LWU零扩展；不能把总线返回宽度直接当作load结果宽度。
  always_comb begin
    selected_byte = 8'(data_memory_resp_i.read_data >>
                       (lsu_req_q.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0] * 8));
    selected_halfword = 16'(data_memory_resp_i.read_data >>
                            (lsu_req_q.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0] * 8));
    selected_word = 32'(data_memory_resp_i.read_data >>
                        (lsu_req_q.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0] * 8));
    formatted_load_data = '0;

    unique case (lsu_req_q.uop.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        formatted_load_data = lsu_req_q.uop.mem_ctrl.unsigned_load
            ? {{(XLEN-8){1'b0}}, selected_byte}
            : {{(XLEN-8){selected_byte[7]}}, selected_byte};
      end
      MEM_SIZE_HALF: begin
        formatted_load_data = lsu_req_q.uop.mem_ctrl.unsigned_load
            ? {{(XLEN-16){1'b0}}, selected_halfword}
            : {{(XLEN-16){selected_halfword[15]}}, selected_halfword};
      end
      MEM_SIZE_WORD: begin
        formatted_load_data = lsu_req_q.uop.mem_ctrl.unsigned_load
            ? xlen_data_t'(selected_word)
            : {{(XLEN-32){selected_word[31]}}, selected_word};
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
  end

  // access_fault来自D-cache、uncached adapter或系统互联，LSU在这里转换成架构异常。
  always_comb begin
    memory_writeback              = '0;
    memory_writeback.uop          = lsu_req_q.uop;
    memory_writeback.result       = is_load ? formatted_load_data : '0;
    memory_writeback.next_pc      = lsu_req_q.next_pc;
    memory_writeback.memory_addr  = lsu_req_q.effective_addr;
    memory_writeback.memory_rdata = is_load ? core_data_t'(formatted_load_data) : '0;
    memory_writeback.memory_wdata = is_store ? store_write_data : '0;
    memory_writeback.memory_wmask = is_store ? store_byte_strobe : '0;

    if (data_memory_resp_i.access_fault) begin
      memory_writeback.uop.exception_valid = 1'b1;
      memory_writeback.uop.exception_cause = is_load
          ? EXC_LOAD_ACCESS_FAULT : EXC_STORE_ACCESS_FAULT;
      memory_writeback.uop.exception_tval = lsu_req_q.effective_addr;
      memory_writeback.result             = '0;
      memory_writeback.memory_rdata       = '0;
    end
  end

  // 第一段：输出逻辑。IDLE支持请求直通到存储层，也支持本地完成直通到completion。
  always_comb begin
    lsu_req_ready_o          = 1'b0;
    data_memory_req_valid_o  = 1'b0;
    data_memory_resp_ready_o = 1'b0;
    lsu_writeback_o          = buffered_writeback_q;
    lsu_writeback_valid_o    = 1'b0;

    unique case (state_q)
      LSU_IDLE: begin
        lsu_req_ready_o = 1'b1;
        if (lsu_req_valid_i) begin
          if (complete_locally) begin
            lsu_writeback_o       = local_writeback;
            lsu_writeback_valid_o = 1'b1;
          end else begin
            data_memory_req_valid_o = 1'b1;
          end
        end
      end

      LSU_SEND_MEMORY_REQUEST: begin
        data_memory_req_valid_o = 1'b1;
      end

      LSU_WAIT_MEMORY_RESPONSE: begin
        data_memory_resp_ready_o = 1'b1;
        lsu_writeback_o           = memory_writeback;
        lsu_writeback_valid_o     = data_memory_resp_valid_i;
      end

      LSU_HOLD_WRITEBACK: begin
        lsu_writeback_o       = buffered_writeback_q;
        lsu_writeback_valid_o = 1'b1;
      end

      default: ;
    endcase
  end

  // 第二段：状态和payload next逻辑。每个本地request只产生一个本地response；
  // AXI4的AR/R或AW/W/B细分事务不能泄漏到本状态机中。
  always_comb begin
    state_d                = state_q;
    lsu_req_d              = lsu_req_q;
    buffered_writeback_d   = buffered_writeback_q;

    unique case (state_q)
      LSU_IDLE: begin
        if (lsu_req_handshake) begin
          lsu_req_d = lsu_req_i;
          if (complete_locally) begin
            if (!lsu_writeback_handshake) begin
              buffered_writeback_d = local_writeback;
              state_d              = LSU_HOLD_WRITEBACK;
            end
          end else if (data_memory_req_handshake) begin
            state_d = LSU_WAIT_MEMORY_RESPONSE;
          end else begin
            state_d = LSU_SEND_MEMORY_REQUEST;
          end
        end
      end

      LSU_SEND_MEMORY_REQUEST: begin
        if (data_memory_req_handshake) begin
          state_d = LSU_WAIT_MEMORY_RESPONSE;
        end
      end

      LSU_WAIT_MEMORY_RESPONSE: begin
        if (data_memory_resp_handshake) begin
          if (lsu_writeback_handshake) begin
            lsu_req_d = '0;
            state_d   = LSU_IDLE;
          end else begin
            buffered_writeback_d = memory_writeback;
            state_d              = LSU_HOLD_WRITEBACK;
          end
        end
      end

      LSU_HOLD_WRITEBACK: begin
        if (lsu_writeback_handshake) begin
          lsu_req_d            = '0;
          buffered_writeback_d = '0;
          state_d              = LSU_IDLE;
        end
      end

      default: begin
        state_d              = LSU_IDLE;
        lsu_req_d            = '0;
        buffered_writeback_d = '0;
      end
    endcase
  end

  // 第三段：按状态、请求身份和响应缓冲分组更新寄存器。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= LSU_IDLE;
    else state_q <= state_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) lsu_req_q <= '0;
    else lsu_req_q <= lsu_req_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) buffered_writeback_q <= '0;
    else buffered_writeback_q <= buffered_writeback_d;
  end

  // 当前顺序核固定只有一个访存在途。未来乱序实现中，load返回按LSQ/ROB tag匹配；
  // store在ROB提交后进入store buffer，再由memory ordering逻辑决定何时对外可见。

endmodule
