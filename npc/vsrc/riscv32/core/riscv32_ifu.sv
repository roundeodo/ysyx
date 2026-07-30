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

    // TODO(ICACHE-IFU-1): 完成riscv32_pkg中的I-cache类型后，在本TODO正下方把AXI端口
    // 替换为IFU到I-cache的typed valid/ready通道。IFU不应知道cache line、way、refill
    // 或AXI字段；它只描述“取哪个PC”和“返回了哪条指令”。建议接口骨架：
    //
    //   output icache_lookup_req_t  icache_lookup_req_o,
    //   output logic                icache_lookup_req_valid_o,
    //   input  logic                icache_lookup_req_ready_i,
    //   input  icache_lookup_resp_t icache_lookup_resp_i,
    //   input  logic                icache_lookup_resp_valid_i,
    //   output logic                icache_lookup_resp_ready_o,
    //
    // 迁移时先保留下面AXI端口和原实现作为可运行参考，待core完成I-cache实例化后再一次性
    // 删除。valid/ready必须独立于payload；valid在握手前保持，ready表示本周期能够接收。
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

  // TODO(ICACHE-IFU-2): 在本TODO正下方用fetch epoch替代单个discard位。
  // `fetch_epoch_q`表示当前允许交付的控制流世代，redirect发生时递增；每个lookup request
  // 保存发出时的epoch，response回来后只有`response.epoch == fetch_epoch_q`才允许进入
  // fetch buffer。旧epoch响应仍要完成cache侧握手，但只产生stale-response事件，不交给IDU。
  // 建议第一版使用1 bit，因为blocking I-cache只有一个未完成miss；未来允许多个outstanding
  // request时扩为参数化宽度，并为每个请求保存epoch。比较必须在response真正握手时完成。
  //
  // 推荐寄存器骨架：
  //   fetch_epoch_t fetch_epoch_q, fetch_epoch_d;
  //   fetch_epoch_t lookup_epoch_q, lookup_epoch_d;
  //   logic         stale_lookup_resp;
  //
  // 下面的discard位是当前AXI直连实现，I-cache通道接通后再删除。
  // 已经发出的请求无法取消时，记录其响应属于错误路径。
  logic discard_axi_resp_q;
  logic discard_axi_resp_d;

  logic ifu_axi_ar_handshake;
  logic ifu_axi_r_handshake;
  logic fetch_entry_handshake;

  // 当前AXI直连路径的请求、响应和下游交付握手。
  assign ifu_axi_ar_handshake  = ifu_axi_arvalid_o && ifu_axi_arready_i;
  assign ifu_axi_r_handshake   = ifu_axi_rvalid_i && ifu_axi_rready_o;
  assign fetch_entry_handshake = fetch_entry_valid_o && fetch_entry_ready_i;

  // 当前AXI RRESP到取指异常的转换。I-cache接入后，该转换下移到refill adapter，
  // IFU直接消费icache_lookup_resp_t中的异常字段。AXI R通道只有RDATA和RRESP：
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

  // 当前AXI直连输出。I-cache迁移完成前保留，用于功能回归和性能基线比较。
  // WAIT_RESP采用fall-through旁路：IDU ready时response和fetch同拍握手；IDU not ready
  // 时IFU接收response，并在时钟沿保存到fetch_entry_q。
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

  // TODO(ICACHE-IFU-3): I-cache端口接通后，在本TODO正下方重写IFU控制逻辑。
  // 推荐保持三段式书写顺序，并按以下责任划分：
  //
  // 输出块：
  // - request状态持续输出`pc_q`和`fetch_epoch_q`，直到lookup request握手；
  // - wait状态只在fetch buffer能够接收时拉高lookup response ready；
  // - IFU不直接判断hit/miss，miss期间由I-cache拉低request ready或延后response；
  // - response与fetch buffer之间保留flow-through路径，空buffer且IDU ready时不额外加拍。
  //
  // next块：
  // - request握手后，顺序PC候选为`pc_q + 4`，但PC只有在该请求最终可继续推进时更新；
  // - redirect优先级最高：保存target、递增epoch、清除尚未交付的fetch buffer内容；
  // - stale response握手后返回request状态，不构造fetch_entry；
  // - current response握手后构造fetch_entry，异常字段原样向commit边界传递；
  // - 下游反压时保持fetch entry稳定，不得重新发送cache请求。
  //
  // 时序块：分别更新FSM、PC/epoch、fetch buffer三类寄存器，使每类状态靠近其用途。
  // 第一版仍可保持单个lookup outstanding；接口中保留frontend_tag和epoch，是为了以后
  // 增加fetch queue、多MSHR及乱序返回时不重新设计IFU与I-cache的契约。frontend_tag
  // 标识具体请求，epoch标识该请求是否仍属于当前控制流，两者不能合并成一个字段。
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

  // TODO(ICACHE-IFU-4): I-cache迁移后，在本TODO正下方用新通道改写断言。
  // 至少检查：lookup request反压期间payload稳定；fetch entry反压期间payload稳定；
  // redirect后旧epoch response永不交付；每个current response最多交付一次；PC始终4-byte对齐。
  // 断言只能观察，不能参与ready、redirect或epoch计算。
  // 下面断言继续检查当前AXI直连基线。
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



  // NOTE(ICACHE-IFU-PERF): I-cache和fetch buffer把memory latency与IDU反压分离。后续分支
  // 预测器只生成PC候选和prediction metadata；redirect仍是唯一恢复入口。增加更多outstanding
  // refill或AXI burst应修改I-cache下游，不应把AXI细节重新泄露到IFU。

endmodule
