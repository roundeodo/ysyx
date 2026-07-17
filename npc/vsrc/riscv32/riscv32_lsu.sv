module riscv32_lsu
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  lsu_req_t lsu_req_i,
    input  logic     lsu_req_valid_i,
    output logic     lsu_req_ready_o,

    output writeback_result_t lsu_writeback_o,
    output logic              lsu_writeback_valid_o,
    input  logic              lsu_writeback_ready_i,

    output mem_req_t  dmem_req_o,
    output logic      dmem_req_valid_o,
    input  logic      dmem_req_ready_i,
    /* verilator lint_off UNUSEDSIGNAL */
    input  mem_resp_t dmem_resp_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic      dmem_resp_valid_i,
    output logic      dmem_resp_ready_o
);

  // LSU只负责形成访存请求、格式化响应和报告完成。DPI、SRAM、MMIO与未来D-cache
  // 都属于dmem通道另一侧，不能在本模块中直接访问。

  typedef enum logic [1:0] {
    LSU_IDLE,
    LSU_SEND_REQ,
    LSU_WAIT_RESP,
    LSU_HOLD_WRITEBACK
  } lsu_state_e;

  lsu_state_e                         state_q;
  lsu_state_e                         state_d;

  // lsu_req_q保存已经从EXU取得所有权的操作。请求握手后，response格式化只能读取它，
  // 不能再读取可能已经变化的lsu_req_i。
  lsu_req_t                           lsu_req_q;
  lsu_req_t                           lsu_req_d;
  lsu_req_t                           active_lsu_req;

  // writeback_q只在completion mux反压时使用；无反压响应直接旁路到writeback端口。
  writeback_result_t                  writeback_q;
  writeback_result_t                  writeback_d;
  writeback_result_t                  local_writeback;
  writeback_result_t                  dmem_writeback;

  mem_req_t                           dmem_req_payload;

  logic                               lsu_req_handshake;
  logic                               dmem_req_handshake;
  logic                               dmem_resp_handshake;
  logic                               lsu_writeback_handshake;

  logic                               is_load;
  logic                               is_store;
  logic                               has_memory_command;
  logic                               size_half;
  logic                               size_word;
  logic                               misaligned;
  logic                               local_completion;
  logic              [           1:0] addr_offset;
  logic              [      XLEN-1:0] store_wdata;
  logic              [BYTE_LANES-1:0] store_wmask;
  logic              [           7:0] byte_rdata;
  logic              [          15:0] half_rdata;
  logic              [      XLEN-1:0] formatted_load_data;

  // TODO(BUS-LSU-HANDSHAKE): 在本TODO正下方写四条连续赋值。
  // 每条都只能是对应valid && ready：
  //
  assign lsu_req_handshake       = lsu_req_valid_i && lsu_req_ready_o;
  assign dmem_req_handshake      = dmem_req_valid_o && dmem_req_ready_i;
  assign dmem_resp_handshake     = dmem_resp_valid_i && dmem_resp_ready_o;
  assign lsu_writeback_handshake = lsu_writeback_valid_o && lsu_writeback_ready_i;
  //
  // lsu_req握手表示LSU取得EXU发来的访存请求；dmem req握手表示memory取得请求；
  // dmem resp握手表示LSU取得响应；lsu_writeback握手表示completion mux取得完成结果。状态转移只使用这些
  // 事件，不能看到单独valid就提前转移。



  // TODO(BUS-LSU-HELPER): 在本TODO正下方写请求语义always_comb，建议严格按以下顺序。
  // 第一步选择当前需要解释的请求：
  //
  //   active_lsu_req = (state_q == LSU_IDLE) ? lsu_req_i : lsu_req_q;
  //
  // IDLE使用EXU当前输入实现请求旁路；SEND_REQ/WAIT_RESP使用已经锁存的lsu_req_q。
  // 随后从active_lsu_req计算：
  //
  //   addr_offset       = active_lsu_req.effective_addr[1:0];
  //   is_load           = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
  //   is_store          = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_STORE;
  //   has_memory_command= is_load || is_store;
  //   size_half         = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_HALF;
  //   size_word         = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_WORD;
  //   misaligned        = has_memory_command &&
  //                       ((size_half && addr_offset[0]) ||
  //                        (size_word && (addr_offset != 2'b00)));
  //   local_completion  = active_lsu_req.uop.exception_valid ||
  //                       misaligned || !has_memory_command;
  //
  // local_completion表示不应访问dmem，而应在LSU内部直接生成一个完成结果。已有异常必须
  // 保留原cause/tval；只有没有已有异常且misaligned时，LSU才能写入misaligned异常。
  // MEM_CMD_NONE是防御路径，不应误报成store misaligned。
  //
  // 在同一个always_comb中先令store_wdata/store_wmask为'0，再按size生成小端lane：
  //
  //   MEM_SIZE_BYTE:
  //     store_wmask = 4'b0001 << addr_offset;
  //     store_wdata = {24'b0, active_lsu_req.store_data[7:0]} << (8*addr_offset);
  //   MEM_SIZE_HALF:
  //     store_wmask = 4'b0011 << addr_offset;
  //     store_wdata = {16'b0, active_lsu_req.store_data[15:0]} << (8*addr_offset);
  //   MEM_SIZE_WORD:
  //     store_wmask = 4'b1111;
  //     store_wdata = active_lsu_req.store_data;
  //
  // misaligned时即使组合逻辑算出了mask，OUTPUT块也必须通过local_completion禁止req valid。

  // combinational logic for internal signal
  always_comb begin
    active_lsu_req = (state_q == LSU_IDLE) ? lsu_req_i : lsu_req_q;
  end


  // TODO(BUS-LSU-REQ): 在本TODO正下方构造dmem_req_payload。先整体清零，再逐字段写：
  //
  //   dmem_req_payload        = '0;
  //   dmem_req_payload.txn_id = '0; // 当前只允许一个outstanding事务
  //   dmem_req_payload.cmd    = active_lsu_req.uop.mem_ctrl.cmd;
  //   dmem_req_payload.size   = active_lsu_req.uop.mem_ctrl.size;
  //   dmem_req_payload.addr   = active_lsu_req.effective_addr;
  //   dmem_req_payload.wdata  = is_store ? store_wdata : '0;
  //   dmem_req_payload.wmask  = is_store ? store_wmask : '0;
  //
  // load的wdata/wmask清零；store的addr仍保留原有效地址，由memory adapter根据wmask完成
  // 字节写入。dmem_req_valid_o不能依赖dmem_req_ready_i，否则可能形成协议死锁。



  // TODO(BUS-LSU-LOAD-FORMAT): 在本TODO正下方写load响应格式化always_comb。
  // dmem_resp_i.rdata是包含目标字节的32位对齐原始数据；offset必须来自lsu_req_q对应地址。
  // 推荐先使用右移统一选择lane：
  //
  //   byte_rdata = dmem_resp_i.rdata >> (8 * lsu_req_q.effective_addr[1:0]);
  //   half_rdata = dmem_resp_i.rdata >> (8 * lsu_req_q.effective_addr[1:0]);
  //
  // 然后根据lsu_req_q.uop.mem_ctrl.size生成formatted_load_data：
  //   BYTE：unsigned_load为1则零扩展byte_rdata，否则按byte_rdata[7]符号扩展；
  //   HALF：unsigned_load为1则零扩展half_rdata，否则按half_rdata[15]符号扩展；
  //   WORD：直接使用dmem_resp_i.rdata。
  //
  // 这里必须使用lsu_req_q，不得使用lsu_req_i。请求发出后EXU输入可能已经改变，
  // 使用当前输入会让response采用另一条指令的offset、size或unsigned_load。



  // TODO(BUS-LSU-LOCAL-WRITEBACK): 在本TODO正下方构造local_writeback。
  // 先local_writeback='0，再从lsu_req_i复制uop、next_pc、effective_addr和store_data。
  // 本地完成没有memory响应，因此result/csr_wdata/memory_rdata清零；store的memory_wdata和
  // memory_wmask使用已经按地址lane移位后的store_wdata/store_wmask。
  //
  // 异常优先级必须写成：
  //
  //   if (!lsu_req_i.uop.exception_valid && misaligned) begin
  //     local_writeback.uop.exception_valid = 1'b1;
  //     local_writeback.uop.exception_cause = is_load ? EXC_LOAD_ADDR_MISALIGNED
  //                                                    : EXC_STORE_ADDR_MISALIGNED;
  //     local_writeback.uop.exception_tval  = lsu_req_i.effective_addr;
  //   end
  //
  // 不能无条件用misaligned覆盖已有exception。local_writeback只在LSU_IDLE使用，所以此处
  // active_lsu_req等于lsu_req_i。



  // TODO(BUS-LSU-DMEM-WRITEBACK): 在本TODO正下方构造dmem_writeback。
  // 元数据来自lsu_req_q，响应数据来自dmem_resp_i：
  //
  //   dmem_writeback              = '0;
  //   dmem_writeback.uop          = lsu_req_q.uop;
  //   dmem_writeback.result       = is_load ? formatted_load_data : '0;
  //   dmem_writeback.next_pc      = lsu_req_q.next_pc;
  //   dmem_writeback.memory_addr  = lsu_req_q.effective_addr;
  //   dmem_writeback.memory_rdata = is_load ? formatted_load_data : '0;
  //   dmem_writeback.memory_wdata = is_store ? store_wdata : '0;
  //   dmem_writeback.memory_wmask = is_store ? store_wmask : '0;
  //
  // 由于WAIT_RESP时active_lsu_req=lsu_req_q，可以复用store_wdata/store_wmask。若
  // dmem_resp_i.exception_valid为1，还要把response中的exception_valid/cause/tval覆盖到
  // dmem_writeback.uop。异常仍必须向commit传递，由commit统一禁止架构副作用并触发trap。



  // TODO(BUS-LSU-OUTPUT): 在本TODO正下方写FSM输出always_comb。先给全部输出默认值：
  //
  //   lsu_req_ready_o       = 1'b0;
  //   dmem_req_o         = '0;
  //   dmem_req_valid_o   = 1'b0;
  //   dmem_resp_ready_o  = 1'b0;
  //   lsu_writeback_o       = writeback_q;
  //   lsu_writeback_valid_o = 1'b0;
  //
  // 再按状态覆盖：
  //
  //   LSU_IDLE:
  //     lsu_req_ready_o=1，因为lsu_req_q和writeback_q都没有占用当前入口容量；
  //     lsu_req_valid_i && local_completion时，输出local_writeback并拉高lsu_writeback_valid_o；
  //     lsu_req_valid_i && !local_completion时，输出dmem_req_payload并拉高req valid。
  //
  //   LSU_SEND_REQ:
  //     持续输出由lsu_req_q形成的dmem_req_payload，并保持req valid=1；
  //     ready=0期间payload必须逐位稳定。
  //
  //   LSU_WAIT_RESP:
  //     dmem_resp_ready_o=1，因为result缓冲当前为空；
  //     lsu_writeback_o=dmem_writeback；
  //     lsu_writeback_valid_o=dmem_resp_valid_i，实现response到completion mux的当拍旁路。
  //
  //   LSU_HOLD_WRITEBACK:
  //     lsu_writeback_o=writeback_q，lsu_writeback_valid_o=1；ready=0期间保持不变。
  //
  // SEND_REQ和HOLD_WRITEBACK只在反压时进入。无反压load/store路径不会额外经过这两个状态。



  // TODO(BUS-LSU-NEXT): 在本TODO正下方写下一状态/下一数据always_comb。
  // 开头必须保持全部寄存器：state_d=state_q、lsu_req_d=lsu_req_q、writeback_d=writeback_q。
  //
  //   LSU_IDLE，在lsu_req_handshake时先执行lsu_req_d=lsu_req_i：
  //     local_completion && lsu_writeback_handshake -> 保持IDLE，结果当拍已消费；
  //     local_completion && !lsu_writeback_handshake -> writeback_d=local_writeback，转HOLD_WRITEBACK；
  //     !local_completion && dmem_req_handshake -> 转WAIT_RESP；
  //     !local_completion && !dmem_req_handshake -> 转SEND_REQ。
  //
  //   LSU_SEND_REQ：dmem_req_handshake后转WAIT_RESP，否则全部保持。
  //
  //   LSU_WAIT_RESP，在dmem_resp_handshake时：
  //     lsu_writeback_handshake -> response已当拍旁路消费，转IDLE；
  //     !lsu_writeback_handshake -> writeback_d=dmem_writeback，转HOLD_WRITEBACK。
  //
  //   LSU_HOLD_WRITEBACK：lsu_writeback_handshake后转IDLE，否则保持writeback_q和valid。
  //
  //   default：state_d=LSU_IDLE，lsu_req_d/writeback_d清零。
  //
  // 注意WAIT_RESP中lsu_writeback_handshake必然包含dmem_resp_valid，因为OUTPUT块令
  // lsu_writeback_valid_o=dmem_resp_valid_i。不要在没有response握手时保存dmem_writeback。



  // TODO(BUS-LSU-REG): 在本TODO正下方写统一时序块：
  //
  //   always_ff @(posedge clk_i or negedge rst_ni) begin
  //     if (!rst_ni) begin
  //       state_q     <= LSU_IDLE;
  //       lsu_req_q   <= '0;
  //       writeback_q <= '0;
  //     end else begin
  //       state_q     <= state_d;
  //       lsu_req_q   <= lsu_req_d;
  //       writeback_q <= writeback_d;
  //     end
  //   end
  //
  // 当前单发射核没有并行年轻访存，暂不增加redirect端口。未来乱序版本中load响应使用
  // ROB/LSQ tag判断有效性；store必须在ROB commit授权后进入store buffer并对cache可见。



  // NOTE(P5): replace the single transaction state with a load queue, store queue,
  // store buffer, replay path, and cache transaction tracking.

endmodule
