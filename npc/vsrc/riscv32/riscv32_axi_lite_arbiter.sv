// Two-to-one AXI4-Lite arbiter for the current NPC memory system.
// IFU is a read-only master; LSU is a read/write master. The requester of each
// accepted read is retained from the AR handshake through the matching R handshake.
module riscv32_axi_lite_arbiter
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    // IFU read-only master side
    input  axi_lite_addr_t ifu_axi_ar_i,
    input  logic           ifu_axi_arvalid_i,
    output logic           ifu_axi_arready_o,
    output axi_lite_r_t    ifu_axi_r_o,
    output logic           ifu_axi_rvalid_o,
    input  logic           ifu_axi_rready_i,

    // LSU read/write master side
    input  axi_lite_addr_t lsu_axi_ar_i,
    input  logic           lsu_axi_arvalid_i,
    output logic           lsu_axi_arready_o,
    output axi_lite_r_t    lsu_axi_r_o,
    output logic           lsu_axi_rvalid_o,
    input  logic           lsu_axi_rready_i,

    input  axi_lite_addr_t lsu_axi_aw_i,
    input  logic           lsu_axi_awvalid_i,
    output logic           lsu_axi_awready_o,
    input  axi_lite_w_t    lsu_axi_w_i,
    input  logic           lsu_axi_wvalid_i,
    output logic           lsu_axi_wready_o,
    output axi_lite_b_t    lsu_axi_b_o,
    output logic           lsu_axi_bvalid_o,
    input  logic           lsu_axi_bready_i,

    // Single AXI4-Lite memory slave side
    output axi_lite_addr_t mem_axi_ar_o,
    output logic           mem_axi_arvalid_o,
    input  logic           mem_axi_arready_i,
    input  axi_lite_r_t    mem_axi_r_i,
    input  logic           mem_axi_rvalid_i,
    output logic           mem_axi_rready_o,

    output axi_lite_addr_t mem_axi_aw_o,
    output logic           mem_axi_awvalid_o,
    input  logic           mem_axi_awready_i,
    output axi_lite_w_t    mem_axi_w_o,
    output logic           mem_axi_wvalid_o,
    input  logic           mem_axi_wready_i,
    input  axi_lite_b_t    mem_axi_b_i,
    input  logic           mem_axi_bvalid_i,
    output logic           mem_axi_bready_o
);

  // The selected requester must be registered before AR is sent. This guarantees
  // that ARADDR/ARPROT and the selected master remain stable while memory stalls AR.
  typedef enum logic [1:0] {
    READ_ARBITRATE,
    READ_SEND_ADDRESS,
    READ_WAIT_RESPONSE
  } read_state_e;

  typedef enum logic {
    READ_REQUESTER_IFU,
    READ_REQUESTER_LSU
  } read_requester_e;

  read_state_e     read_state_q;
  read_state_e     read_state_d;
  read_requester_e active_read_requester_q;
  read_requester_e active_read_requester_d;

  // last_served_requester_q records which requester completed the previous AR
  // handshake. When both masters request together, select the other requester to
  // implement transaction-level round-robin fairness. Update it only on AR handshake.
  read_requester_e last_served_requester_q;
  read_requester_e last_served_requester_d;

  // Combinational arbitration result. It is meaningful only when
  // selected_read_request_valid is high in READ_ARBITRATE.
  read_requester_e selected_read_requester;
  logic            selected_read_request_valid;

  logic mem_ar_handshake;
  logic mem_r_handshake;

  assign mem_ar_handshake = mem_axi_arvalid_o && mem_axi_arready_i;
  assign mem_r_handshake  = mem_axi_rvalid_i && mem_axi_rready_o;

  // Requester selection. This block does not drive any AXI channel. It decides
  // which requester will be registered when the arbiter is free.
  always_comb begin
    selected_read_requester     = READ_REQUESTER_IFU;
    selected_read_request_valid = 1'b0;

    // TODO(AXI-ARB-SELECT): 在本TODO正下方完成round-robin请求方选择。
    // 这里完全不使用mem_axi_arready_i，也不产生任何handshake，只检查两个master的
    // ARVALID。建议按以下顺序写if/else if：
    // 1. IFU和LSU同时请求：selected_read_request_valid=1；如果上次服务IFU，这次选LSU，
    //    否则选IFU。可以用三目运算符，也可以再写一个if。
    // 2. 只有IFU请求：valid=1，requester=READ_REQUESTER_IFU。
    // 3. 只有LSU请求：valid=1，requester=READ_REQUESTER_LSU。
    // 4. 都没有请求：保持上面的默认值，不能凭空启动事务。
    // 参考结构：
    // if (ifu_axi_arvalid_i && lsu_axi_arvalid_i) begin
    //   selected_read_request_valid = ...;
    //   selected_read_request = (last_served_requester_q == READ_REQUESTER_IFU) ? ... : ...;
    // end else if (ifu_axi_arvalid_i) begin
    //   ...
    // end else if (lsu_axi_arvalid_i) begin
    //   ...
    // end
  end

  // Read-channel routing. Arbitration, AR forwarding, and R forwarding happen
  // in different states so a stalled channel can never change its requester.
  always_comb begin
    ifu_axi_arready_o = 1'b0;
    ifu_axi_r_o       = '0;
    ifu_axi_rvalid_o  = 1'b0;

    lsu_axi_arready_o = 1'b0;
    lsu_axi_r_o       = '0;
    lsu_axi_rvalid_o  = 1'b0;

    mem_axi_ar_o      = '0;
    mem_axi_arvalid_o = 1'b0;
    mem_axi_rready_o  = 1'b0;

    // TODO(AXI-ARB-READ-ROUTE): 在本TODO正下方完成READ_SEND_ADDRESS和
    // READ_WAIT_RESPONSE的通道路由。READ_ARBITRATE只做选择，不发送AXI请求。
    //
    // READ_SEND_ADDRESS：active_read_requester_q已经由寄存器锁定。
    // - 若是IFU：mem AR payload=ifu AR payload；mem ARVALID=ifu ARVALID；
    //   ifu ARREADY=mem ARREADY。LSU ARREADY继续保持默认0。
    // - 若是LSU：进行对应的三项连接，IFU ARREADY保持0。
    // - 不需要写if(handshake)。VALID/payload/READY直接连接，握手仅用于状态转移。
    //
    // READ_WAIT_RESPONSE：根据active_read_requester_q把memory响应送回原请求方。
    // - 若是IFU：ifu R payload=mem R payload；ifu RVALID=mem RVALID；
    //   mem RREADY=ifu RREADY。LSU RVALID保持0。
    // - 若是LSU：进行对应的三项连接，IFU RVALID保持0。
    // - 禁止用mem_r_handshake产生RVALID；RVALID必须独立于RREADY。
    //
    // 可直接采用以下case框架：
    // unique case (read_state_q)
    //   READ_SEND_ADDRESS: begin
    //     if (active_read_requester_q == READ_REQUESTER_IFU) begin
    //       mem_axi_ar_o      = ...;
    //       mem_axi_arvalid_o = ...;
    //       ifu_axi_arready_o = ...;
    //     end else begin
    //       ...LSU对应连接...
    //     end
    //   end
    //   READ_WAIT_RESPONSE: begin
    //     if (active_read_requester_q == READ_REQUESTER_IFU) begin
    //       ifu_axi_r_o      = ...;
    //       ifu_axi_rvalid_o = ...;
    //       mem_axi_rready_o = ...;
    //     end else begin
    //       ...LSU对应连接...
    //     end
    //   end
    //   default: ;
    // endcase
  end

  // The current IFU has no write channel, so LSU write traffic requires no
  // arbitration. Keep AW, W, and B as three independent direct connections.
  always_comb begin
    lsu_axi_awready_o = 1'b0;
    lsu_axi_wready_o  = 1'b0;
    lsu_axi_b_o       = '0;
    lsu_axi_bvalid_o  = 1'b0;

    mem_axi_aw_o      = '0;
    mem_axi_awvalid_o = 1'b0;
    mem_axi_w_o       = '0;
    mem_axi_wvalid_o  = 1'b0;
    mem_axi_bready_o  = 1'b0;

    // TODO(AXI-ARB-WRITE-ROUTE): 在本TODO正下方连接LSU与memory的AW/W/B通道。
    // 这里不需要case，也不需要状态机，逐项写9条直接赋值：
    // mem_axi_aw_o      = lsu_axi_aw_i;
    // mem_axi_awvalid_o = lsu_axi_awvalid_i;
    // lsu_axi_awready_o = mem_axi_awready_i;
    // mem_axi_w_o       = ...;
    // mem_axi_wvalid_o  = ...;
    // lsu_axi_wready_o  = ...;
    // lsu_axi_b_o       = ...;
    // lsu_axi_bvalid_o  = ...;
    // mem_axi_bready_o  = ...;
    // AW与W是独立通道，不要增加“二者同时有效/同时ready”这样的附加条件。
  end

  // Read requester locking, address transfer, response transfer, and fairness state.
  always_comb begin
    read_state_d            = read_state_q;
    active_read_requester_d = active_read_requester_q;
    last_served_requester_d = last_served_requester_q;

    // TODO(AXI-ARB-READ-NEXT): 在本TODO正下方完成读仲裁状态转移。
    // 用unique case (read_state_q)实现：
    //
    // READ_ARBITRATE：
    // - 如果selected_read_request_valid=1，把selected_read_requester写入
    //   active_read_requester_d，然后进入READ_SEND_ADDRESS。
    // - 此时还没有AR握手，所以不要更新last_served_requester_d。
    //
    // READ_SEND_ADDRESS：
    // - active_read_requester_d保持默认值，不再重新仲裁。
    // - mem_ar_handshake发生时，说明地址请求真正被memory接收：把
    //   active_read_requester_q写入last_served_requester_d，并进入READ_WAIT_RESPONSE。
    //
    // READ_WAIT_RESPONSE：
    // - mem_r_handshake发生后，本次读事务彻底结束，返回READ_ARBITRATE。
    // - 没握手时保持当前状态和requester，保证R反压期间路由不变。
    //
    // default：恢复READ_ARBITRATE；两个requester的_d都赋READ_REQUESTER_IFU，避免X扩散。
    // 参考框架：
    // unique case (read_state_q)
    //   READ_ARBITRATE: begin
    //     if (selected_read_request_valid) begin ... end
    //   end
    //   READ_SEND_ADDRESS: begin
    //     if (mem_ar_handshake) begin ... end
    //   end
    //   READ_WAIT_RESPONSE: begin
    //     if (mem_r_handshake) begin ... end
    //   end
    //   default: begin ... end
    // endcase
  end

  // TODO(AXI-ARB-REGS): 在本TODO正下方写唯一的时序寄存器块。
  // 使用always_ff @(posedge clk_i or negedge rst_ni)。复位时：
  // - read_state_q <= READ_ARBITRATE；
  // - active_read_requester_q <= READ_REQUESTER_IFU；
  // - last_served_requester_q <= READ_REQUESTER_IFU；这样复位后两者同时请求时先服务LSU。
  // 非复位时分别执行q<=d。三个_q寄存器只能在这个always_ff中赋值。
  // 完整结构：
  // always_ff @(posedge clk_i or negedge rst_ni) begin
  //   if (!rst_ni) begin
  //     ...三个复位赋值...
  //   end else begin
  //     ...三个q<=d...
  //   end
  // end

  // TODO(AXI-ARB-ASSERT): 功能完成并接入top后，在本TODO正下方增加协议断言。
  // 最少检查：
  // 1. IFU和LSU的AR握手不能同周期同时发生。
  // 2. READ_SEND_ADDRESS和READ_WAIT_RESPONSE期间active_read_requester_q保持稳定。
  // 3. 每个mem R握手之前必须存在一个已经完成的IFU或LSU AR握手。
  // 4. mem ARVALID && !ARREADY时，下一拍ARVALID和{ARADDR, ARPROT}保持稳定。
  // 5. mem RVALID只能被active_read_requester_q对应的master看到，另一路RVALID必须为0。
  // 6. reset期间所有输出VALID为0。

endmodule
