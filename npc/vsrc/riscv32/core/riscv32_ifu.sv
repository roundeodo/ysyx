module riscv32_ifu
  import riscv32_pkg::*;
#(
    parameter logic [XLEN-1:0] PC_START = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    /* verilator lint_off UNUSEDSIGNAL */
    input redirect_req_t redirect_req_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic          redirect_req_valid_i,

    // TODO(AXI-IFU-PORTS): 将下面6个SimpleBus端口替换为AXI4-Lite只读master的AR/R端口。
    // ARM IHI 0022H A9.2.2明确允许read-only interface只包含AR和R，不需要伪造AW/W/B。
    // 建议端口骨架：
    // output axi_lite_addr_t ifu_axi_ar_o,
    // output logic           ifu_axi_arvalid_o,
    // input  logic           ifu_axi_arready_i,
    // input  axi_lite_r_t    ifu_axi_r_i,
    // input  logic           ifu_axi_rvalid_i,
    // output logic           ifu_axi_rready_o,
    output axi_lite_addr_t ifu_axi_ar_o,
    output logic           ifu_axi_arvalid_o,
    input  logic           ifu_axi_arready_i,
    input  axi_lite_r_t    ifu_axi_r_i,
    input  logic           ifu_axi_rvalid_i,
    output logic           ifu_axi_rready_o,
    //
    // 删除imem_req/imem_resp命名后，valid/ready方向必须按master角色检查：
    // ARVALID/ARADDR由IFU产生，ARREADY由memory产生；RVALID/RDATA/RRESP由memory产生，
    // RREADY由IFU产生。不要把RREADY误写成slave输出方向。

    output fetch_entry_t fetch_entry_o,
    output logic         fetch_entry_valid_o,
    input  logic         fetch_entry_ready_i
);

  // IFU_INIT保证复位期间ARVALID为0；正常取指循环不会返回该状态。
  // 当前只允许一个outstanding read，AR握手后必须等待对应R握手。
  // AXI4-Lite没有ID，因此删除txn_id不能靠总线字段关联PC；fetch_req_pc_q继续承担关联责任。
  typedef enum logic [1:0] {
    IFU_INIT,
    IFU_SEND_AR,
    IFU_WAIT_R,
    IFU_HOLD_FETCH
  } ifu_state_e;

  ifu_state_e state_q;
  ifu_state_e state_d;

  // fetch_req_pc_q在请求阻塞和等待响应期间保持不变，用于关联响应与取指PC。
  logic [XLEN-1:0] fetch_req_pc_q;
  logic [XLEN-1:0] fetch_req_pc_d;
  // next_pc_q保存当前事务结束后的顺序PC，redirect到达时保存redirect target。
  logic [XLEN-1:0] next_pc_q;
  logic [XLEN-1:0] next_pc_d;

  // 该寄存器只在memory响应已经被IFU接收、但IDU尚未ready时使用。
  // 无反压时，响应在IFU_WAIT_RESP中直接旁路到IDU，不额外增加一拍。
  fetch_entry_t fetch_entry_q;
  fetch_entry_t fetch_entry_d;
  fetch_entry_t axi_resp_fetch_entry;

  // 已经发出的请求无法取消时，记录其响应属于错误路径。
  logic discard_axi_resp_q;
  logic discard_axi_resp_d;

  logic ifu_axi_ar_handshake;
  logic ifu_axi_r_handshake;
  logic fetch_entry_handshake;

  // TODO(AXI-IFU-HANDSHAKE): 用AR/R握手替换下面两个imem握手：
  // ar_handshake = ifu_axi_arvalid_o && ifu_axi_arready_i;
  // r_handshake  = ifu_axi_rvalid_i  && ifu_axi_rready_o;
  // 状态只能在对应握手发生后推进。master不能等待ARREADY才拉高ARVALID；ARVALID一旦拉高，
  // 在握手前不能撤销，即使这期间收到redirect也只能标记discard并完成旧事务。
  assign ifu_axi_ar_handshake  = ifu_axi_arvalid_o && ifu_axi_arready_i;
  assign ifu_axi_r_handshake   = ifu_axi_rvalid_i && ifu_axi_rready_o;
  assign fetch_entry_handshake = fetch_entry_valid_o && fetch_entry_ready_i;

  // TODO(AXI-IFU-RRESP): 将下面的SimpleBus异常字段转换改成RRESP解码。
  // AXI R通道只有RDATA和RRESP，不提供exception_cause/tval：
  // - AXI_RESP_OKAY：instruction=RDATA，exception_valid=0。
  // - AXI_RESP_SLVERR或AXI_RESP_DECERR：exception_valid=1，
  //   exception_cause=EXC_INSTR_ACCESS_FAULT，exception_tval=fetch_req_pc_q。
  // - AXI_RESP_EXOKAY在Lite中不合法；仿真中assert，功能上按access fault防御处理。
  // 即使RRESP报错，本次R传输仍必须完成握手；错误作为有效fetch送到有序commit边界。
  //
  // 取指异常仍作为有效fetch向后传递。只有到达有序commit边界后，trap controller
  // 才能更新CSR并产生redirect，从而保持精确异常语义。
  always_comb begin
    axi_resp_fetch_entry                 = '0;
    axi_resp_fetch_entry.pc              = fetch_req_pc_q;
    axi_resp_fetch_entry.instruction     = ifu_axi_r_i.data;
    axi_resp_fetch_entry.frontend_tag    = '0;
    axi_resp_fetch_entry.prediction      = '0;
    axi_resp_fetch_entry.exception_valid = ifu_axi_r_i.resp != AXI_RESP_OKAY;
    axi_resp_fetch_entry.exception_cause = EXC_INSTR_ACCESS_FAULT;
    axi_resp_fetch_entry.exception_tval  = fetch_req_pc_q;
  end

  // TODO(AXI-IFU-OUTPUT): 用AR/R信号重写本输出块，但保留当前单outstanding旁路结构。
  // IFU_SEND_AR中无条件基于已保存PC拉高ARVALID，不能组合依赖ARREADY；ARADDR和ARPROT在
  // ARVALID && !ARREADY期间必须稳定。建议ARADDR={fetch_req_pc_q[XLEN-1:2], 2'b00}；
  // 当前只取32-bit指令，正常PC本来就应word aligned。ARPROT至少明确instruction属性。
  //
  // IFU_WAIT_R中可以让RREADY=1，因为本地fetch_entry_q能吸收一个受IDU反压的响应。
  // 这样RREADY不依赖RVALID，也不会形成AXI输入到输出的组合路径。RVALID && !RREADY时
  // RDATA/RRESP稳定是slave责任，不要在IFU中假定响应只保持一拍。
  //
  // WAIT_RESP采用fall-through旁路：IDU ready时response和fetch同拍握手；
  // IDU not ready时IFU接收response，并在时钟沿保存到fetch_entry_q。
  // Moore output
  always_comb begin
    ifu_axi_arvalid_o   = 1'b0;
    ifu_axi_rready_o    = 1'b0;
    fetch_entry_o       = fetch_entry_q;
    fetch_entry_valid_o = 1'b0;
    ifu_axi_ar_o.addr   = '0;
    ifu_axi_ar_o.prot   = 3'b101;

    unique case (state_q)
      IFU_INIT: ;

      IFU_SEND_AR: begin
        ifu_axi_arvalid_o = 1'b1;
        ifu_axi_ar_o.addr = fetch_req_pc_q;
      end

      IFU_WAIT_R: begin
        // 此状态下本地响应缓冲为空，所以总能接收一个memory响应。已经由discard位确认
        // 属于错误路径的响应不能交给IDU；redirect不能直接组合门控valid，因为它可能由
        // 当前fetch在同一周期产生。
        ifu_axi_rready_o    = 1'b1;
        fetch_entry_o       = axi_resp_fetch_entry;
        fetch_entry_valid_o = ifu_axi_rvalid_i && !discard_axi_resp_q;
      end

      IFU_HOLD_FETCH: begin
        fetch_entry_o       = fetch_entry_q;
        fetch_entry_valid_o = 1'b1;
      end

      default: ;
    endcase
  end

  // TODO(AXI-IFU-NEXT): 将状态转移事件逐一替换为AR/R握手，不要按单独valid推进。
  // redirect处理规则保持不变：
  // 1. ARVALID尚未握手但已经拉高时，AXI禁止撤回AR，只能保持payload并标记discard。
  // 2. AR已握手后，AXI没有cancel通道，必须接收并丢弃旧R响应。
  // 3. 丢弃旧R响应后才能用redirect target发新AR。
  // 未来要允许多个outstanding read时，单个discard位不够，必须增加按请求顺序保存PC与
  // discard状态的FIFO；AXI4-Lite没有ID，返回顺序必须与请求顺序一致。
  //
  // next state
  always_comb begin
    state_d            = state_q;
    fetch_req_pc_d     = fetch_req_pc_q;
    next_pc_d          = next_pc_q;
    fetch_entry_d      = fetch_entry_q;
    discard_axi_resp_d = discard_axi_resp_q;

    unique case (state_q)
      IFU_INIT: begin
        state_d = IFU_SEND_AR;
      end

      IFU_SEND_AR: begin
        // valid && !ready期间不能改变request payload。redirect先记录为后续PC，
        // 当前旧请求仍完成传输，其响应回来后再丢弃。
        if (redirect_req_valid_i) begin
          next_pc_d          = redirect_req_i.target_pc;
          discard_axi_resp_d = 1'b1;
        end

        if (ifu_axi_ar_handshake) begin
          state_d = IFU_WAIT_R;
          if (!discard_axi_resp_q && !redirect_req_valid_i) begin
            next_pc_d = fetch_req_pc_q + XLEN'(4);
          end
        end
      end

      IFU_WAIT_R: begin
        // 已握手的memory请求无法撤回。redirect到达后保存新PC，并等待旧响应回来。
        if (redirect_req_valid_i) begin
          next_pc_d          = redirect_req_i.target_pc;
          discard_axi_resp_d = 1'b1;
        end

        if (ifu_axi_r_handshake) begin
          if (discard_axi_resp_q || redirect_req_valid_i) begin
            // 消耗错误路径响应，但不构造fetch。
            fetch_req_pc_d     = redirect_req_valid_i ? redirect_req_i.target_pc : next_pc_q;
            next_pc_d          = redirect_req_valid_i ? redirect_req_i.target_pc : next_pc_q;
            discard_axi_resp_d = 1'b0;
            state_d            = IFU_SEND_AR;
          end else if (fetch_entry_handshake) begin
            // 无反压快速路径：响应当拍直接交给IDU，不进入HOLD_FETCH。
            fetch_req_pc_d = next_pc_q;
            state_d        = IFU_SEND_AR;
          end else begin
            // IDU反压：响应已被IFU接收，保存后由HOLD_FETCH持续展示。
            fetch_entry_d = axi_resp_fetch_entry;
            state_d       = IFU_HOLD_FETCH;
          end
        end
      end

      IFU_HOLD_FETCH: begin
        if (redirect_req_valid_i) begin
          // 缓冲中的fetch尚未交给IDU，可以直接丢弃。
          fetch_req_pc_d     = redirect_req_i.target_pc;
          next_pc_d          = redirect_req_i.target_pc;
          discard_axi_resp_d = 1'b0;
          state_d            = IFU_SEND_AR;
        end else if (fetch_entry_handshake) begin
          fetch_req_pc_d = next_pc_q;
          state_d        = IFU_SEND_AR;
        end
      end

      default: begin
        state_d            = IFU_INIT;
        fetch_req_pc_d     = PC_START;
        next_pc_d          = PC_START;
        fetch_entry_d      = '0;
        discard_axi_resp_d = 1'b0;
      end
    endcase
  end

  // IFU_INIT已经保证reset期间ARVALID为0。寄存器块仍是状态、请求PC和fetch缓冲的唯一写入点。



  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q            <= IFU_INIT;
      fetch_req_pc_q     <= PC_START;
      next_pc_q          <= PC_START;
      fetch_entry_q      <= '0;
      discard_axi_resp_q <= 1'b0;
    end else begin
      state_q            <= state_d;
      fetch_req_pc_q     <= fetch_req_pc_d;
      next_pc_q          <= next_pc_d;
      fetch_entry_q      <= fetch_entry_d;
      discard_axi_resp_q <= discard_axi_resp_d;
    end
  end

  // TODO(AXI-IFU-ASSERT): 添加以下等价SVA检查：
  // - ARVALID && !ARREADY |=> ARVALID && $stable({ARADDR, ARPROT})
  // - ARVALID在握手前不能下降
  // - 每个R握手之前必须存在一个尚未完成的AR握手
  // 断言放在master侧用于检查IFU责任；RVALID/RDATA稳定性放在slave侧检查。
  //
  // Register update
  always_comb begin
    if (!rst_ni) begin
      p_ifu_arvalid_low_during_reset :
      assert (!ifu_axi_arvalid_o)
      else $error("IFU ARVALID assert during reset");
    end
  end

  p_ifu_ar_stabler_while_stall :
  assert property(
    @(posedge clk_i)
    ifu_axi_arvalid_o && !ifu_axi_arready_i |=> ifu_axi_arvalid_o && $stable(
      {ifu_axi_ar_o.addr, ifu_axi_ar_o.prot}
  ))
  else $error("IFU changed AR payload before handshake");

  p_ifu_arvalid_only_in_send_state :
  assert property(
    @(posedge clk_i)
    ifu_axi_arvalid_o |-> state_q == IFU_SEND_AR
  )
  else $error("IFU assert ARVALID in an invalid state");



  // TODO(AXI-IFU-PERF): 基线通过后再消除气泡，不要把性能优化混入第一次协议迁移。
  // 第一阶段保持1个outstanding。第二阶段可在AR前增加1-entry skid/request buffer，并让
  // RREADY在fetch buffer有空间时常高。再往后增加顺序PC FIFO支持多个outstanding Lite读；
  // 若I-cache refill需要burst或ID，应在I-cache的memory侧升级到完整AXI4，而不是向Lite
  // 私自添加ARLEN/ARID。
  //
  // NOTE(P5): branch prediction, I-cache response tracking, and a fetch queue
  // extend this boundary; redirect remains the only external PC-recovery input.

endmodule
