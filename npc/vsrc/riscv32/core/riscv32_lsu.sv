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
    output logic     lsu_transaction_active_o,

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
    program_counter_t next_pc;
    effective_addr_t  effective_addr;
    xlen_data_t       store_data;
  } pending_lsu_context_t;

  pending_lsu_context_t pending_lsu_context_q;
  lsu_req_t active_lsu_req;

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
  logic                                           is_load;
  logic                                           is_store;
  logic                                           has_memory_access;
  logic                                           is_halfword_access;
  logic                                           is_word_access;
  logic                                           is_doubleword_access;
  logic                                           address_misaligned;
  logic                                           complete_locally;
  logic              [CORE_BYTE_OFFSET_WIDTH-1:0] byte_offset;
  core_data_t                                     store_write_data;
  // strobe描述core数据口每个字节通道是否写入，它取决于CORE_DATA_WIDTH，而不是XLEN。
  core_byte_strobe_t                              store_byte_strobe;
  logic              [                       7:0] selected_byte;
  logic              [                      15:0] selected_halfword;
  logic              [                      31:0] selected_word;
  xlen_data_t                                     formatted_load_data;

  assign lsu_req_handshake          = lsu_req_valid_i && lsu_req_ready_o;
  // 该状态只描述已经被LSU接收但尚未完成的存储事务，不从ready反推，因而不会
  // 把当前输入valid重新反馈到流水线允许信号中形成组合环。
  assign lsu_transaction_active_o   = state_q != LSU_IDLE;
  assign data_memory_req_handshake  = data_memory_req_valid_o && data_memory_req_ready_i;
  assign data_memory_resp_handshake = data_memory_resp_valid_i && data_memory_resp_ready_o;

  // IDLE时直接使用输入实现零额外入口延迟；请求被接受后，从紧凑上下文重建LSU仍需
  // 使用的字段。未重建字段保持0，因为它们不参与memory response或架构提交。
  // byte_offset按core beat宽度选择字节通道；自然对齐仍按ISA访问大小判断：
  // half只检查bit 0，word检查bits[1:0]。
  // 不要用总线beat宽度替代ISA对齐规则；总线即使是64位，LW仍只要求4字节对齐。
  always_comb begin
    active_lsu_req = '0;
    if (state_q == LSU_IDLE) begin
      active_lsu_req = lsu_req_i;
    end else begin
      active_lsu_req.uop.pc          = pending_lsu_context_q.pc;
      active_lsu_req.uop.instruction = pending_lsu_context_q.instruction;
      active_lsu_req.uop.rd          = pending_lsu_context_q.rd;
      active_lsu_req.uop.writes_rd   = pending_lsu_context_q.writes_rd;
      active_lsu_req.uop.mem_ctrl    = pending_lsu_context_q.mem_ctrl;
      active_lsu_req.next_pc         = pending_lsu_context_q.next_pc;
      active_lsu_req.effective_addr  = pending_lsu_context_q.effective_addr;
      active_lsu_req.store_data      = pending_lsu_context_q.store_data;
    end

    byte_offset          = active_lsu_req.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0];
    is_load              = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
    is_store             = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_STORE;
    has_memory_access    = is_load || is_store;
    is_halfword_access   = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_HALF;
    is_word_access       = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_WORD;
    is_doubleword_access = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_DOUBLE;

    address_misaligned = has_memory_access &&
                         ((is_halfword_access && byte_offset[0]) ||
                         (is_word_access &&
                         (active_lsu_req.effective_addr[1:0] != 2'b00)) ||
                         (is_doubleword_access &&
                         (active_lsu_req.effective_addr[2:0] != 3'b000)));
    complete_locally   = active_lsu_req.uop.exception_valid ||
                         address_misaligned || !has_memory_access;

    // strobe只覆盖本条store写入的字节。WORD不能使用'1，否则64位存储口会误写8字节。
    store_write_data  = '0;
    store_byte_strobe = '0;
    unique case (active_lsu_req.uop.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        store_byte_strobe = core_byte_strobe_t'(1) << byte_offset;
        store_write_data  = core_data_t'(active_lsu_req.store_data[7:0]) << (byte_offset * 8);
      end
      MEM_SIZE_HALF: begin
        store_byte_strobe = core_byte_strobe_t'(2'b11) << byte_offset;
        store_write_data  = core_data_t'(active_lsu_req.store_data[15:0]) << (byte_offset * 8);
      end
      MEM_SIZE_WORD: begin
        store_byte_strobe = core_byte_strobe_t'(4'b1111) << byte_offset;
        store_write_data  = core_data_t'(active_lsu_req.store_data[31:0]) << (byte_offset * 8);
      end
      MEM_SIZE_DOUBLE: begin
        // RV64的SD覆盖完整core beat。RV32中的同一编码已经由IDU标记为非法，
        // 因此这里使用类型转换而不是引用不存在的store_data[63:32]。
        store_byte_strobe = '1;
        store_write_data  = core_data_t'(active_lsu_req.store_data);
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
    data_memory_req_o.write_data     = is_store ? store_write_data : '0;
    data_memory_req_o.byte_strobe    = is_store ? store_byte_strobe : '0;
    data_memory_req_o.transaction_id = '0;
  end

  // 存储层返回完整数据字。LSU根据原始地址低位选择byte/halfword并完成符号扩展。
  // RV64下LW将bit 31符号扩展，LWU零扩展；不能把总线返回宽度直接当作load结果宽度。
  always_comb begin
    selected_byte       = 8'(data_memory_resp_i.read_data >>
                          (pending_lsu_context_q.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0] * 8));
    selected_halfword   = 16'(data_memory_resp_i.read_data >>
                          (pending_lsu_context_q.effective_addr[CORE_BYTE_OFFSET_WIDTH-1:0] * 8));
    selected_word       = 32'(data_memory_resp_i.read_data >>
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
      local_writeback.uop.exception_tval  = active_lsu_req.effective_addr;
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
    memory_writeback.result          = is_load ? formatted_load_data : '0;
    memory_writeback.next_pc         = pending_lsu_context_q.next_pc;
    memory_writeback.memory_addr     = pending_lsu_context_q.effective_addr;
    memory_writeback.memory_rdata    = is_load ? core_data_t'(formatted_load_data) : '0;
    memory_writeback.memory_wdata    = is_store ? store_write_data : '0;
    memory_writeback.memory_wmask    = is_store ? store_byte_strobe : '0;

    if (data_memory_resp_i.access_fault) begin
      memory_writeback.uop.exception_valid = 1'b1;
      memory_writeback.uop.exception_cause = is_load
                                             ? EXC_LOAD_ACCESS_FAULT : EXC_STORE_ACCESS_FAULT;
      memory_writeback.uop.exception_tval  = pending_lsu_context_q.effective_addr;
      memory_writeback.result              = '0;
      memory_writeback.memory_rdata        = '0;
    end
  end

  // 第一段：输出逻辑。IDLE支持请求直通到存储层，也支持本地完成直通到completion。
  // 本地完成只在completion能够接收时接收LSU请求；存储响应则把completion的
  // ready直接传回存储层。因此反压期间由原始发送方保持payload，LSU不需要再复制
  // 一整份writeback_result_t。这是标准ready/valid反压，不改变接口协议。
  always_comb begin
    lsu_req_ready_o          = 1'b0;
    data_memory_req_valid_o  = 1'b0;
    data_memory_resp_ready_o = 1'b0;
    lsu_writeback_o          = '0;
    lsu_writeback_valid_o    = 1'b0;

    unique case (state_q)
      LSU_IDLE: begin
        lsu_req_ready_o = !lsu_req_valid_i || !complete_locally || lsu_writeback_ready_i;
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
        if (lsu_req_handshake && !complete_locally) begin
          if (data_memory_req_handshake) begin
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
          state_d = LSU_IDLE;
        end
      end

      default: begin
        state_d = LSU_IDLE;
      end
    endcase
  end

  // 第三段：状态和紧凑请求上下文分组更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= LSU_IDLE;
    else state_q <= state_d;
  end

  // pending payload不复位。state_q=IDLE时它没有语义；仅在接受需要访问存储层的请求时
  // 覆盖一次。这样既删除无关字段，也避免给纯数据payload构造异步复位网络。
  always_ff @(posedge clk_i) begin
    if (lsu_req_handshake && !complete_locally) begin
      pending_lsu_context_q.pc             <= lsu_req_i.uop.pc;
      pending_lsu_context_q.instruction    <= lsu_req_i.uop.instruction;
      pending_lsu_context_q.rd             <= lsu_req_i.uop.rd;
      pending_lsu_context_q.writes_rd      <= lsu_req_i.uop.writes_rd;
      pending_lsu_context_q.mem_ctrl       <= lsu_req_i.uop.mem_ctrl;
      pending_lsu_context_q.next_pc        <= lsu_req_i.next_pc;
      pending_lsu_context_q.effective_addr <= lsu_req_i.effective_addr;
      pending_lsu_context_q.store_data     <= lsu_req_i.store_data;
    end
  end

  // 当前顺序核固定只有一个访存在途。未来乱序实现中，load返回按LSQ/ROB tag匹配；
  // store在ROB提交后进入store buffer，再由memory ordering逻辑决定何时对外可见。

endmodule
