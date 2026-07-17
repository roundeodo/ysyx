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

    // TODO(AXI-LSU-PORTS): 删除下面SimpleBus dmem request/response端口，替换为完整的
    // AXI4-Lite read/write master五通道端口。推荐顺序为AR、R、AW、W、B：
    // output axi_lite_addr_t lsu_axi_ar_o;  output logic lsu_axi_arvalid_o;
    // input  logic           lsu_axi_arready_i;
    // input  axi_lite_r_t    lsu_axi_r_i;   input logic lsu_axi_rvalid_i;
    // output logic           lsu_axi_rready_o;
    // output axi_lite_addr_t lsu_axi_aw_o;  output logic lsu_axi_awvalid_o;
    // input  logic           lsu_axi_awready_i;
    // output axi_lite_w_t    lsu_axi_w_o;   output logic lsu_axi_wvalid_o;
    // input  logic           lsu_axi_wready_i;
    // input  axi_lite_b_t    lsu_axi_b_i;   input logic lsu_axi_bvalid_i;
    // output logic           lsu_axi_bready_o;
    //
    output axi_lite_addr_t lsu_axi_ar_o,
    output logic           lsu_axi_arvalid_o,
    input  logic           lsu_axi_arready_i,

    input  axi_lite_r_t lsu_axi_r_i,
    input  logic        lsu_axi_rvalid_i,
    output logic        lsu_axi_rready_o,

    output axi_lite_addr_t lsu_axi_aw_o,
    output logic           lsu_axi_awvalid_o,
    input  logic           lsu_axi_awready_i,

    output axi_lite_w_t lsu_axi_w_o,
    output logic        lsu_axi_wvalid_o,
    input  logic        lsu_axi_wready_i,

    input  axi_lite_b_t lsu_axi_b_i,
    input  logic        lsu_axi_bvalid_i,
    output logic        lsu_axi_bready_o
    // AR/AW/W的VALID和payload由LSU产生，R/B的READY也由LSU产生。不要保留cmd/size作为
    // AXI信号：Lite没有读写cmd，也没有AxSIZE；读写方向由使用AR还是AW/W表示。
);

  // LSU只负责形成访存请求、格式化响应和报告完成。DPI、SRAM、MMIO与未来D-cache
  // 都属于dmem通道另一侧，不能在本模块中直接访问。

  // TODO(AXI-LSU-STATE): 当前LSU_SEND_REQ/WAIT_RESP无法表达五个独立通道，替换为至少：
  // LSU_IDLE、LSU_SEND_AR、LSU_WAIT_R、LSU_SEND_AW_W、LSU_WAIT_B、
  // LSU_HOLD_WRITEBACK。状态位宽相应改为3bit。
  //
  // store的AW与W必须在同一状态并行尝试，但分别用aw_done_q/w_done_q记录是否已经握手。
  // 不能写成“先等AW握手，再拉WVALID”，否则虽然可能工作，却损失并行性，并容易与某些
  // 等待WVALID才给AWREADY的slave形成死锁。只有两个done都为1后才能进入WAIT_B。
  typedef enum logic [2:0] {
    LSU_IDLE,
    LSU_SEND_AR,
    LSU_WAIT_R,
    LSU_SEND_AW,
    LSU_WAIT_B,
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
  writeback_result_t                  no_dmem_writeback;
  writeback_result_t                  dmem_writeback;

  mem_req_t                           dmem_req_payload;

  // TODO(AXI-LSU-CHANNEL-STATE): 用独立channel payload和握手状态替换dmem_req_payload：
  // axi_lite_addr_t ar_payload/aw_payload; axi_lite_w_t w_payload;
  // logic ar_handshake, r_handshake, aw_handshake, w_handshake, b_handshake;
  // logic aw_done_q/aw_done_d, w_done_q/w_done_d;
  //
  // done位表示本store的对应channel已经交给slave。AW握手不能清掉WVALID，W握手也不能
  // 清掉AWVALID。每次接收新store时两个done清零；各自握手时独立置1；B握手完成后清零。
  // 基线只允许一个CPU访存，因此不需要AXI ID，也不需要地址/数据队列。

  axi_lite_addr_t                     ar_payload;
  axi_lite_addr_t                     aw_payload;

  axi_lite_w_t                        w_payload;
  logic                               ar_hanshake;
  logic                               r_handshake;
  logic                               aw_hanshake;
  logic                               w_handshake;
  logic                               b_handshake;

  logic                               aw_done_q;
  logic                               aw_done_d;

  logic                               w_done_q;
  logic                               w_done_d;



  logic                               is_load;
  logic                               is_store;
  logic                               has_dmem_access;
  logic                               is_halfword_access;
  logic                               is_word_access;
  logic                               misaligned;
  logic                               complete_without_dmem;
  logic              [           1:0] byte_offset;
  logic              [      XLEN-1:0] store_wdata;
  logic              [BYTE_LANES-1:0] store_wmask;
  logic              [           7:0] selected_byte;
  logic              [          15:0] selected_halfword;
  logic              [      XLEN-1:0] formatted_load_data;

  // TODO(AXI-LSU-HANDSHAKE): 删除dmem_req_handshake/dmem_resp_handshake，分别定义五个
  // AXI握手。一个load事务包含AR和R两次握手；一个store事务包含AW、W、B三次握手。
  // AW和W握手没有先后依赖，B必须在两者都完成后才可能出现。状态转移只能使用握手，
  // 不能看到RVALID/BVALID就提前释放lsu_req_q。
  //
  // 每个handshake都只表示对应通道在本周期完成一次传输。
  assign lsu_req_handshake       = lsu_req_valid_i && lsu_req_ready_o;
  assign dmem_req_handshake      = dmem_req_valid_o && dmem_req_ready_i;
  assign dmem_resp_handshake     = dmem_resp_valid_i && dmem_resp_ready_o;
  assign lsu_writeback_handshake = lsu_writeback_valid_o && lsu_writeback_ready_i;
  // lsu_req握手表示LSU取得EXU发来的访存请求；dmem req握手表示memory取得请求；
  // dmem resp握手表示LSU取得响应；lsu_writeback握手表示completion mux取得完成结果。状态转移只使用这些
  // 事件，不能看到单独valid就提前转移。



  // TODO(BUS-LSU-HELPER): 请求解释与store lane生成。
  // 块类型：纯always_comb辅助逻辑，不是FSM，也不更新任何_q寄存器。
  // 本块负责写：active_lsu_req、byte_offset、is_load/is_store、has_dmem_access、
  // is_halfword_access/is_word_access、misaligned、complete_without_dmem、
  // store_wdata和store_wmask。后续REQ、WRITEBACK和FSM块只能读取这些结果。
  //
  // active_lsu_req选择“当前事务的所有者”：IDLE尚未接收请求，可以直接读取lsu_req_i；
  // 进入SEND_REQ/WAIT_RESP后，EXU输入可能变化，只能读取握手时保存的lsu_req_q。
  // byte_offset取有效地址低两位，因为32-bit数据总线内共有4个byte lane。
  // is_load/is_store只解释cmd；has_dmem_access把MEM_CMD_NONE隔离为LSU本地完成路径。
  // misaligned只对真实load/store检查：half要求addr[0]=0，word要求addr[1:0]=0。
  // complete_without_dmem为1时禁止发memory请求：已有异常、未对齐或NONE都在LSU内部完成。
  //
  // store_wdata/store_wmask必须先清零，保证所有case路径均有赋值且load不会产生写副作用。
  // case的选择量是active_lsu_req.uop.mem_ctrl.size，不是FSM状态。

  // generate store
  always_comb begin
    active_lsu_req = (state_q == LSU_IDLE) ? lsu_req_i : lsu_req_q;

    byte_offset           = active_lsu_req.effective_addr[1:0];
    is_load               = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
    is_store              = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_STORE;
    has_dmem_access       = is_load || is_store;
    is_halfword_access    = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_HALF;
    is_word_access        = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_WORD;
    misaligned            = has_dmem_access && ((is_halfword_access && byte_offset[0]) || (is_word_access && (byte_offset != 2'b00)));
    complete_without_dmem = active_lsu_req.uop.exception_valid || misaligned || !has_dmem_access;

    store_wdata = '0;
    store_wmask = '0;

    unique case (active_lsu_req.uop.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        // TODO: 只使能byte_offset指定的1个lane，并把store_data[7:0]移到对应lane。
        store_wmask = 4'b0001 << byte_offset;
        store_wdata = {24'b0, active_lsu_req.store_data[7:0]} << {byte_offset, 3'b000};
      end

      MEM_SIZE_HALF: begin
        // TODO: 使能从byte_offset开始的2个lane，并移动store_data[15:0]。
        store_wmask = 4'b0011 << byte_offset;
        store_wdata = {16'b0, active_lsu_req.store_data[15:0]} << {byte_offset, 3'b000};
      end

      MEM_SIZE_WORD: begin
        // TODO: word使用全部lane，数据不需要移动；未对齐访问稍后被FSM禁止发送。
        store_wmask = 4'b1111;
        store_wdata = active_lsu_req.store_data;
      end
    endcase
  end


  // TODO(AXI-LSU-PAYLOAD): 完成AXI类型后删除整个BUS-LSU-REQ块，改成三个独立payload块：
  // 1. load AR：addr按32-bit总线宽度向下对齐，prot标记data access。
  // 2. store AW：addr同样按32-bit总线宽度向下对齐，prot标记data access。
  // 3. store W：data=store_wdata，strb=store_wmask。
  //
  // AXI4-Lite所有访问使用完整数据总线宽度且没有AxSIZE。byte/half load仍读取一个32-bit
  // aligned word，再根据lsu_req_q.effective_addr[1:0]选择lane；byte/half store依靠WSTRB
  // 限定真正写入的lane。effective_addr原值继续保存在lsu_req_q供异常tval和trace使用，
  // 不能因为ARADDR/AWADDR对齐而覆盖它。
  //
  // payload只能由已保存事务产生，并且VALID && !READY期间必须稳定。第一次迁移可取消
  // IDLE直通AXI的快速路径，先在lsu_req握手后寄存请求；协议通过后再用1-entry skid
  // buffer恢复零气泡接收。

  // TODO(BUS-LSU-REQ): 构造发给dmem的payload。
  // 块类型：独立always_comb数据打包块，不是FSM；它只形成payload，不决定valid。
  // 本块负责写：dmem_req_payload的全部字段。
  // 本块读取：active_lsu_req、is_store、store_wdata、store_wmask。
  // OUTPUT块负责把payload接到dmem_req_o并根据state产生dmem_req_valid_o。
  //
  // 代码结构：
  // always_comb begin
  //   dmem_req_payload        = '0;  // 先清整个struct，防止遗漏字段产生锁存器。
  //   dmem_req_payload.txn_id = '0;  // 当前每次只允许一个事务，暂时不需要区分ID。
  //   dmem_req_payload.cmd    = active_lsu_req.uop.mem_ctrl.cmd;
  //                                  // cmd告诉memory执行load还是store。
  //   dmem_req_payload.size   = active_lsu_req.uop.mem_ctrl.size;
  //                                  // size决定memory访问BYTE/HALF/WORD。
  //   dmem_req_payload.addr   = active_lsu_req.effective_addr;
  //                                  // 使用EXU已经计算好的有效地址，不在LSU重复计算。
  //   dmem_req_payload.wdata  = is_store ? store_wdata : '0;
  //                                  // load没有写数据，必须显式清零。
  //   dmem_req_payload.wmask  = is_store ? store_wmask : '0;
  //                                  // load不能打开任何写lane；store使用HELPER块生成的mask。
  // end
  //
  // 注意：不要在本块写dmem_req_valid_o，也不要让valid组合依赖ready。valid属于OUTPUT/FSM，
  // payload属于本块；两者分开后，SEND_REQ反压期间payload才能保持稳定。
  // construct payload
  always_comb begin
    dmem_req_payload        = '0;
    dmem_req_payload.txn_id = '0;
    dmem_req_payload.cmd    = active_lsu_req.uop.mem_ctrl.cmd;
    dmem_req_payload.size   = active_lsu_req.uop.mem_ctrl.size;
    dmem_req_payload.addr   = active_lsu_req.effective_addr;
    dmem_req_payload.wdata  = is_store ? store_wdata : '0;
    dmem_req_payload.wmask  = is_store ? store_wmask : '0;
  end


  // TODO(AXI-LSU-LOAD-FORMAT): 把本块的数据源从dmem_resp_i.rdata改为lsu_axi_r_i.data。
  // lane选择和符号/零扩展逻辑不因协议变化而改变，因为AXI4-Lite读返回完整32-bit数据。
  // 仍必须使用lsu_req_q中的低地址位，不能使用已向下对齐的ARADDR。
  //
  // TODO(BUS-LSU-LOAD-FORMAT): 从memory原始响应中选择lane并扩展到XLEN。
  // 块类型：独立always_comb数据格式化块，不是FSM。
  // 本块负责写：selected_byte、selected_halfword、formatted_load_data。
  // 本块读取：dmem_resp_i.rdata和lsu_req_q中的地址、size、unsigned_load。
  // 必须读取lsu_req_q，因为响应对应的是已经握手的旧请求，此时lsu_req_i可能属于下一条指令。
  //
  // 代码结构：
  // always_comb begin
  //   selected_byte = dmem_resp_i.rdata >> (8 * lsu_req_q.effective_addr[1:0]);
  //                         // 将目标byte移动到bit[7:0]，后续不再分别枚举4个lane。
  //   selected_halfword = dmem_resp_i.rdata >> (8 * lsu_req_q.effective_addr[1:0]);
  //                         // 将目标half移动到bit[15:0]；未对齐half不会进入WAIT_RESP。
  //   formatted_load_data = '0;
  //                         // 非法size的防御默认值，同时覆盖所有组合路径。
  //
  //   unique case (lsu_req_q.uop.mem_ctrl.size)
  //     MEM_SIZE_BYTE: begin
  //       // TODO: unsigned_load=1时在selected_byte左侧补0，否则复制selected_byte[7]。
  //       // formatted_load_data = lsu_req_q.uop.mem_ctrl.unsigned_load ? ... : ...;
  //     end
  //     MEM_SIZE_HALF: begin
  //       // TODO: unsigned_load=1时在selected_halfword左侧补0，否则复制bit[15]。
  //       // formatted_load_data = lsu_req_q.uop.mem_ctrl.unsigned_load ? ... : ...;
  //     end
  //     MEM_SIZE_WORD: begin
  //       // TODO: 32-bit word已经等于XLEN，直接使用完整rdata。
  //       // formatted_load_data = dmem_resp_i.rdata;
  //     end
  //     default: begin
  //       // 保持formatted_load_data='0。
  //     end
  //   endcase
  // end

  // process with the read data
  always_comb begin
    selected_byte       = 8'(dmem_resp_i.rdata >> ({lsu_req_q.effective_addr[1:0], 3'b000}));
    selected_halfword   = 16'(dmem_resp_i.rdata >> ({lsu_req_q.effective_addr[1:0], 3'b000}));
    formatted_load_data = '0;

    unique case (lsu_req_q.uop.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        formatted_load_data = lsu_req_q.uop.mem_ctrl.unsigned_load? {24'b0,selected_byte} : {{24{selected_byte[7]}}, selected_byte};
      end
      MEM_SIZE_HALF: begin
        formatted_load_data = lsu_req_q.uop.mem_ctrl.unsigned_load? {16'b0,selected_halfword} : {{16{selected_halfword[15]}}, selected_halfword};
      end
      MEM_SIZE_WORD: begin
        formatted_load_data = dmem_resp_i.rdata;
      end
      default: ;
    endcase
  end



  // TODO(BUS-LSU-NO-DMEM-WRITEBACK): 构造“不访问memory也能完成”的结果。
  // 块类型：独立always_comb数据打包块，不是FSM。
  // 本块负责写：no_dmem_writeback整个struct。
  // 使用场景：OUTPUT块只会在LSU_IDLE且complete_without_dmem=1时选择它，因此元数据直接
  // 来自lsu_req_i；它覆盖已有异常、地址未对齐和MEM_CMD_NONE三类本地完成路径。
  //
  // 代码结构：
  // always_comb begin
  //   no_dmem_writeback              = '0;  // 清掉所有与本地完成无关的结果字段。
  //   no_dmem_writeback.uop          = lsu_req_i.uop;
  //                                          // 保留原指令、rd、控制信息和已有exception。
  //   no_dmem_writeback.result       = '0;  // 没有load响应，不能产生有效GPR数据。
  //   no_dmem_writeback.next_pc      = lsu_req_i.next_pc;
  //                                          // commit仍需知道该指令的顺序next_pc。
  //   no_dmem_writeback.csr_wdata    = '0;  // LSU不执行CSR操作。
  //   no_dmem_writeback.memory_addr  = lsu_req_i.effective_addr;
  //                                          // 保留发生异常或尝试访问的有效地址用于trace。
  //   no_dmem_writeback.memory_rdata = '0;  // 没有memory response。
  //   no_dmem_writeback.memory_wdata = is_store ? store_wdata : '0;
  //                                          // store保留lane对齐后的数据，load保持0。
  //   no_dmem_writeback.memory_wmask = is_store ? store_wmask : '0;
  //                                          // 仅用于结果记录；FSM不会把未对齐store发给memory。
  //
  //   if (!lsu_req_i.uop.exception_valid && misaligned) begin
  //     no_dmem_writeback.uop.exception_valid = 1'b1;
  //                                          // 仅在没有更早异常时创建LSU异常。
  //     no_dmem_writeback.uop.exception_cause = is_load ? EXC_LOAD_ADDR_MISALIGNED
  //                                                       : EXC_STORE_ADDR_MISALIGNED;
  //                                          // cmd决定load/store两种不同架构异常号。
  //     no_dmem_writeback.uop.exception_tval  = lsu_req_i.effective_addr;
  //                                          // mtval需要报告发生未对齐的有效地址。
  //   end
  // end
  //
  // 不要无条件覆盖exception：IDU/EXU已经发现的异常年龄更早，必须保留原cause和tval。
  always_comb begin
    no_dmem_writeback     = 'd0;
    no_dmem_writeback.uop = active_lsu_req.uop;

    no_dmem_writeback.result  = '0;
    no_dmem_writeback.next_pc = active_lsu_req.next_pc;

    no_dmem_writeback.csr_wdata   = '0;
    no_dmem_writeback.memory_addr = active_lsu_req.effective_addr;

    no_dmem_writeback.memory_rdata = '0;
    no_dmem_writeback.memory_wdata = is_store ? store_wdata : '0;

    no_dmem_writeback.memory_wmask = is_store ? store_wmask : '0;

    if (!active_lsu_req.uop.exception_valid && misaligned) begin
      no_dmem_writeback.uop.exception_valid = 1'b1;

      no_dmem_writeback.uop.exception_cause = is_load? EXC_LOAD_ADDR_MISALIGNED : EXC_STORE_ADDR_MISALIGNED;

      no_dmem_writeback.uop.exception_tval = active_lsu_req.effective_addr;
    end
  end


  // TODO(AXI-LSU-RESP-FAULT): 删除dmem_resp_i.exception_*依赖，按事务类型解码响应：
  // - load在R握手时检查RRESP；SLVERR/DECERR产生EXC_LOAD_ACCESS_FAULT。
  // - store在B握手时检查BRESP；SLVERR/DECERR产生EXC_STORE_ACCESS_FAULT。
  // - exception_tval均使用lsu_req_q.effective_addr。
  // - EXOKAY不属于AXI4-Lite，assert并按access fault防御处理。
  // store没有RDATA，必须等B响应后才能向commit报告完成；不能在AW或W握手时提前退休。
  // 对错误load，RDATA不具备架构意义，result/memory_rdata清零后再提交异常更容易调试。
  //
  // TODO(BUS-LSU-DMEM-WRITEBACK): 把已握手memory事务的响应封装成完成结果。
  // 块类型：独立always_comb数据打包块，不是FSM。
  // 本块负责写：dmem_writeback整个struct。
  // 本块读取：lsu_req_q保存的请求、格式化后的load数据、store lane数据和dmem_resp_i异常。
  // 请求元数据必须来自lsu_req_q，响应数据必须来自dmem_resp_i，二者属于同一个已发事务。
  //
  // 代码结构：
  always_comb begin
    dmem_writeback     = '0;  // 默认清空LSU不负责的CSR等字段。
    dmem_writeback.uop = lsu_req_q.uop;
    // 恢复发请求时保存的指令身份和控制信息。
    dmem_writeback.result       = is_load ? formatted_load_data : '0;
    // load写回扩展后的数据，store不写GPR结果。
    dmem_writeback.next_pc      = lsu_req_q.next_pc;
    // 继续传递该指令的控制流元数据。
    dmem_writeback.csr_wdata   = '0;  // LSU不产生CSR写数据。
    dmem_writeback.memory_addr = lsu_req_q.effective_addr;
    // trace/commit记录原始有效地址。
    dmem_writeback.memory_rdata = is_load ? formatted_load_data : '0;
    // 记录架构可见的load值，而不是未选择lane的原始总线值。
    dmem_writeback.memory_wdata = is_store ? store_wdata : '0;
    dmem_writeback.memory_wmask = is_store ? store_wmask : '0;
    // store记录实际发送给memory的lane数据和byte mask。

    if (dmem_resp_i.exception_valid) begin
      dmem_writeback.uop.exception_valid = 1'b1;
      dmem_writeback.uop.exception_cause = dmem_resp_i.exception_cause;
      dmem_writeback.uop.exception_tval  = dmem_resp_i.exception_tval;
      // memory访问错误覆盖正常完成信息，交给commit精确处理。
    end
  end



  // TODO(AXI-LSU-OUTPUT): 完成新状态后删除BUS-LSU-OUTPUT实现，按以下规则重写：
  // - SEND_AR：ARVALID=1并持续展示ar_payload，直到AR握手。
  // - WAIT_R：只要本地writeback buffer为空就RREADY=1；R握手后旁路或缓存结果。
  // - SEND_AW_W：AWVALID=!aw_done_q，WVALID=!w_done_q；两通道同时发起、独立停止。
  // - WAIT_B：BREADY=1；B握手后旁路或缓存store完成结果。
  // - HOLD_WRITEBACK：只保持内部writeback，不再驱动任何AXI请求。
  //
  // 所有AXI输出先给安全默认值。特别禁止：
  // - ARVALID组合依赖ARREADY，AWVALID组合依赖AWREADY，WVALID组合依赖WREADY。
  // - BREADY组合依赖BVALID或RREADY组合依赖RVALID。
  // - 用AWREADY控制WVALID，或用WREADY控制AWVALID。
  // 这些依赖会违反source不得等待READY的规则，或者形成接口输入到输出组合路径。
  //
  // TODO(BUS-LSU-OUTPUT): 根据state_q驱动四个valid/ready接口及其payload。
  // 块类型：FSM的组合输出块（Moore输出加IDLE/WAIT_RESP旁路），不更新state_q。
  // 本块负责写：lsu_req_ready_o、dmem_req_o、dmem_req_valid_o、dmem_resp_ready_o、
  // lsu_writeback_o、lsu_writeback_valid_o。不要在NEXT或REG块再次写这些端口。
  //
  // 所有输出先给安全默认值，case只覆盖当前状态需要拉高或替换的信号：
  // Moore output
  always_comb begin
    lsu_req_ready_o   = 1'b0;  // 默认不接收新的EXU请求。
    dmem_req_o        = '0;  // valid=0时payload清零，避免传播无意义数据。
    dmem_req_valid_o  = 1'b0;  // 只有IDLE真实访存或SEND_REQ才能发请求。
    dmem_resp_ready_o = 1'b0;  // 只有WAIT_RESP才拥有一个待接收响应。
    lsu_writeback_o   = writeback_q;
    // 默认展示缓冲值，HOLD状态无需重新选择。
    lsu_writeback_valid_o = 1'b0;  // 只有本地完成、响应旁路或HOLD才有完成结果。

    unique case (state_q)
      LSU_IDLE: begin
        lsu_req_ready_o = 1'b1;  // 当前没有占用事务，可以接收一个EXU请求。
        if (lsu_req_valid_i) begin
          if (complete_without_dmem) begin
            // TODO: 选择no_dmem_writeback并拉高writeback valid。
            // 这样已有异常、misaligned和NONE不访问memory也能完成。
            lsu_writeback_o       = no_dmem_writeback;
            lsu_writeback_valid_o = 1'b1;
          end else begin
            // TODO: 选择dmem_req_payload并拉高dmem request valid。
            // 这里允许EXU请求在IDLE当拍直接旁路到memory，减少一拍延迟。
            dmem_req_o       = dmem_req_payload;
            dmem_req_valid_o = 1'b1;
          end
        end
      end

      LSU_SEND_REQ: begin
        // TODO: 持续输出dmem_req_payload并保持dmem_req_valid_o=1。
        // active_lsu_req此时来自lsu_req_q，因此ready=0期间payload不会随EXU输入变化。
        dmem_req_o       = dmem_req_payload;
        dmem_req_valid_o = 1'b1;
      end

      LSU_WAIT_RESP: begin
        // TODO: dmem_resp_ready_o=1，选择dmem_writeback，valid跟随dmem_resp_valid_i。
        // 本地writeback_q此时为空，所以可以无条件接收response；下游ready=1时同拍旁路，
        // 下游ready=0时NEXT块会在时钟沿把dmem_writeback保存到writeback_q。
        dmem_resp_ready_o     = 1'b1;
        lsu_writeback_o       = dmem_writeback;
        lsu_writeback_valid_o = dmem_resp_valid_i;
      end

      LSU_HOLD_WRITEBACK: begin
        // TODO: 持续输出writeback_q并保持lsu_writeback_valid_o=1。
        // completion mux反压期间不能修改payload，也不能接收新LSU请求。
        dmem_resp_ready_o     = 1'b0;
        lsu_writeback_o       = writeback_q;
        lsu_writeback_valid_o = 1'b1;
      end

      default: begin
        // 保持安全默认值；NEXT块会把非法状态恢复到LSU_IDLE。
      end
    endcase
  end



  // TODO(AXI-LSU-NEXT): 用下面的事务级转移替换BUS-LSU-NEXT：
  // - 本地异常/misaligned/NONE：保持当前no-dmem完成路径，不发任何AXI VALID。
  // - load：接收lsu_req后进入SEND_AR；AR握手进入WAIT_R；R握手后完成或HOLD。
  // - store：接收lsu_req后进入SEND_AW_W；每个AW/W握手设置自己的done；
  //   当(aw_done_q || aw_handshake) && (w_done_q || w_handshake)时进入WAIT_B；
  //   B握手后完成或HOLD。
  //
  // 上式必须包含“旧done或本拍handshake”，否则AW和W同拍握手时状态机会多停一拍，
  // 或者只看到一个旧done而遗漏完成条件。进入WAIT_B之前不能假定slave已经执行写入，
  // 架构上的store成功只由OKAY BRESP确认。
  //
  // TODO(BUS-LSU-NEXT): 计算FSM下一状态和三个寄存器的下一值。
  // 块类型：FSM组合下一状态块；它只写state_d、lsu_req_d、writeback_d。
  // 状态转移只使用四个handshake，不允许只看到valid或ready就转移。
  //
  always_comb begin
    state_d     = state_q;  // 默认保持状态，避免每个分支重复写“停留”。
    lsu_req_d   = lsu_req_q;  // 默认保持已取得所有权的请求。
    writeback_d = writeback_q;  // 默认保持下游尚未接收的完成结果。

    unique case (state_q)
      LSU_IDLE: begin
        if (lsu_req_handshake) begin
          lsu_req_d = lsu_req_i;
          // 握手表示LSU取得请求所有权，后续不能再依赖lsu_req_i。
          if (complete_without_dmem) begin
            if (lsu_writeback_handshake) begin
              // TODO: 保持LSU_IDLE；本地结果已经在同一拍被completion mux接收。
              state_d = LSU_IDLE;
            end else begin
              // TODO: writeback_d=no_dmem_writeback并转LSU_HOLD_WRITEBACK。
              // 请求已接收但下游反压，必须把组合结果保存起来。
              state_d     = LSU_HOLD_WRITEBACK;
              writeback_d = no_dmem_writeback;
            end
          end else if (dmem_req_handshake) begin
            // TODO: 转LSU_WAIT_RESP；memory已经取得请求，下一步只能等待响应。
            state_d = LSU_WAIT_RESP;
          end else begin
            // TODO: 转LSU_SEND_REQ；LSU已取得EXU请求，但memory尚未ready。
            state_d = LSU_SEND_REQ;
          end
        end
      end

      LSU_SEND_REQ: begin
        if (dmem_req_handshake) begin
          // TODO: 转LSU_WAIT_RESP；ready之前必须停留并保持request payload。
          state_d = LSU_WAIT_RESP;
        end
      end

      LSU_WAIT_RESP: begin
        if (dmem_resp_handshake) begin
          if (lsu_writeback_handshake) begin
            // TODO: 转LSU_IDLE；response已旁路给completion mux，无需写writeback_q。
            state_d = LSU_IDLE;
          end else begin
            // TODO: writeback_d=dmem_writeback并转LSU_HOLD_WRITEBACK。
            // memory响应已经被LSU接收，下游反压时只能由本地寄存器保存。
            writeback_d = dmem_writeback;
            state_d     = LSU_HOLD_WRITEBACK;
          end
        end
      end

      LSU_HOLD_WRITEBACK: begin
        if (lsu_writeback_handshake) begin
          // TODO: 转LSU_IDLE；缓冲结果的所有权已经交给completion mux。
          state_d = LSU_IDLE;
        end
      end

      default: begin
        // TODO: state_d=LSU_IDLE，并把lsu_req_d/writeback_d清零。
        // 非法状态恢复时不能把不确定payload继续传播到外部接口。
        state_d     = LSU_IDLE;
        lsu_req_d   = '0;
        writeback_d = '0;
      end
    endcase
  end



  // TODO(AXI-LSU-REG-ASSERT): 在现有寄存器块中加入aw_done_q/w_done_q更新和reset。
  // reset期间ARVALID/AWVALID/WVALID必须为0；若状态复位会组合产生VALID，必须增加reset门控
  // 或registered valid，不能依赖仿真初值。
  //
  // master侧至少增加这些协议断言：
  // - 各VALID && !READY时，下一拍VALID仍为1且对应payload保持稳定。
  // - AW握手次数、W握手次数和B握手次数对每个store恰好各一次。
  // - 未发AR时不能接受R，AW/W未全部完成时不能接受B。
  // - load期间AWVALID/WVALID=0，store期间ARVALID=0。
  //
  // TODO(BUS-LSU-REG): 在本TODO正下方写唯一的时序更新块。
  // 块类型：always_ff寄存器块；这是本模块唯一写state_q、lsu_req_q、writeback_q的位置。
  // _d全部由NEXT组合块生成，_q只在时钟沿更新，不能在OUTPUT或数据打包块中改_q。
  //
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= LSU_IDLE;  // reset后没有在途请求，也没有待写回结果。
      lsu_req_q   <= '0;  // 清除旧请求，避免reset释放后传播未知控制字段。
      writeback_q <= '0;  // 清除可能被HOLD状态展示的旧结果。
    end else begin
      state_q     <= state_d;  // 提交本周期组合逻辑算出的状态转移。
      lsu_req_q   <= lsu_req_d; // 仅在NEXT块决定接收请求时捕获新payload，否则保持。
      writeback_q <= writeback_d;
      // 仅在下游反压时捕获结果，否则保持或由NEXT清理。
    end
  end
  //
  // 当前单发射核没有并行年轻访存，暂不增加redirect端口。未来乱序版本中load响应使用
  // ROB/LSQ tag判断有效性；store必须在ROB commit授权后进入store buffer并对cache可见。



  // TODO(AXI-LSU-PERF-UPGRADE): 第一次实现维持单outstanding，但不要人为串行AW和W。
  // 后续性能升级顺序：
  // 1. lsu_req入口加1-entry skid buffer，AXI反压时仍能可靠保存payload。
  // 2. R/B接收各加1-entry response buffer，使RREADY/BREADY尽可能常高。
  // 3. 若允许多个outstanding Lite事务，增加按请求顺序保存元数据的load/store FIFO；
  //    Lite没有ID，不能乱序匹配响应。
  // 4. 若需要cache-line burst、多个ID或乱序响应，升级cache外侧为完整AXI4，不要扩展
  //    这个Lite接口的私有字段。
  // 5. 未来乱序CPU的store必须先经ROB commit授权进入store buffer，协议转换不能替代
  //    精确异常和memory ordering设计。
  //
  // NOTE(P5): replace the single transaction state with a load queue, store queue,
  // store buffer, replay path, and cache transaction tracking.

endmodule
