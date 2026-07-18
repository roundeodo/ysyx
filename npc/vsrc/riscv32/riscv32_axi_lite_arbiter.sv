// Two-to-one AXI4-Lite arbiter for the current NPC memory system.
// IFU is a read-only master; LSU is a read/write master. Read ownership is
// retained from the AR handshake through the matching R handshake.
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

  // A read owner is meaningful only after one AR transfer has completed and
  // before its matching R transfer completes. AXI4-Lite has no transaction ID,
  // so the arbiter must retain this owner locally instead of re-arbitrating R.
  typedef enum logic {
    READ_SELECT,
    READ_WAIT_R
  } read_state_e;

  typedef enum logic {
    READ_OWNER_IFU,
    READ_OWNER_LSU
  } read_owner_e;

  read_state_e read_state_q;
  read_state_e read_state_d;
  read_owner_e read_owner_q;
  read_owner_e read_owner_d;

  // last_grant_q records the previous successful AR grant. When both masters
  // request together, choose the other master to implement transaction-level
  // round-robin fairness. Update it on AR handshake, not merely on arbitration.
  read_owner_e last_grant_q;
  read_owner_e last_grant_d;

  logic ifu_ar_handshake;
  logic lsu_ar_handshake;
  logic mem_r_handshake;

  assign ifu_ar_handshake = ifu_axi_arvalid_i && ifu_axi_arready_o;
  assign lsu_ar_handshake = lsu_axi_arvalid_i && lsu_axi_arready_o;
  assign mem_r_handshake  = mem_axi_rvalid_i && mem_axi_rready_o;

  // Combinational channel routing
  always_comb begin
    // Defaults disconnect both read masters and hold every source VALID low.
    // Keeping complete defaults here prevents latches while each state only
    // overrides the channels that belong to the selected transaction.
    ifu_axi_arready_o = 1'b0;
    ifu_axi_r_o       = '0;
    ifu_axi_rvalid_o  = 1'b0;

    lsu_axi_arready_o = 1'b0;
    lsu_axi_r_o       = '0;
    lsu_axi_rvalid_o  = 1'b0;

    mem_axi_ar_o      = '0;
    mem_axi_arvalid_o = 1'b0;
    mem_axi_rready_o  = 1'b0;

    lsu_axi_awready_o = 1'b0;
    lsu_axi_wready_o  = 1'b0;
    lsu_axi_b_o       = '0;
    lsu_axi_bvalid_o  = 1'b0;

    mem_axi_aw_o      = '0;
    mem_axi_awvalid_o = 1'b0;
    mem_axi_w_o       = '0;
    mem_axi_wvalid_o  = 1'b0;
    mem_axi_bready_o  = 1'b0;

    // TODO(AXI-ARB-READ-ROUTE): 在本TODO正下方按read_state_q完成AR/R路由。
    // READ_SELECT中：
    // 1. 若只有一个master的ARVALID为1，选择该master。
    // 2. 若两者同时有效，根据last_grant_q选择上次未获准的一方。
    // 3. 把被选master的AR payload/ARVALID转发到mem端，并且只把mem ARREADY
    //    返回给被选master；未选master的ARREADY必须保持0。
    // 4. 选择逻辑只能依赖两个ARVALID和last_grant_q，不能等待mem_axi_arready_i
    //    才产生mem_axi_arvalid_o，否则违反VALID不得依赖READY的要求。
    // READ_WAIT_R中：
    // 1. read_owner_q为IFU时，仅向IFU转发R payload/RVALID，并把IFU RREADY转给mem。
    // 2. read_owner_q为LSU时同理；绝不能在等待R期间重新根据当前ARVALID选择owner。
    // 3. RVALID && !RREADY期间，路由选择必须保持不变，因此owner只能来自寄存器。
    // 建议骨架：
    // unique case (read_state_q)
    //   READ_SELECT: begin
    //     if (选择IFU) begin ... end
    //     else if (选择LSU) begin ... end
    //   end
    //   READ_WAIT_R: begin
    //     if (read_owner_q == READ_OWNER_IFU) begin ... end
    //     else begin ... end
    //   end
    // endcase

    // TODO(AXI-ARB-WRITE-ROUTE): 在本TODO正下方连接LSU与memory的AW/W/B通道。
    // 当前IFU没有写通道，所以写路径不需要竞争，可以逐通道直接转发：
    // - AW payload/VALID向memory，memory AWREADY返回LSU。
    // - W payload/VALID向memory，memory WREADY返回LSU。
    // - B payload/VALID返回LSU，LSU BREADY转给memory。
    // AW和W必须保持两套独立握手，不能用AWREADY门控WVALID，也不能等待二者同时ready。
  end

  // Read transaction ownership and fairness state
  always_comb begin
    read_state_d = read_state_q;
    read_owner_d = read_owner_q;
    last_grant_d = last_grant_q;

    // TODO(AXI-ARB-READ-NEXT): 在本TODO正下方完成读仲裁状态转移。
    // READ_SELECT：只有ifu_ar_handshake或lsu_ar_handshake发生时才能进入READ_WAIT_R。
    // 同一个周期只能有一个AR握手；握手后把对应master写入read_owner_d，同时更新
    // last_grant_d。仅仅看到ARVALID不能锁定owner，因为请求尚未被memory接收。
    // READ_WAIT_R：一直保持read_owner_d不变，只有mem_r_handshake发生后才能回到
    // READ_SELECT。这样下一笔AR不可能覆盖尚未返回的响应归属。
    // default分支应恢复READ_SELECT，并给owner/fairness一个确定值。
  end

  // TODO(AXI-ARB-REGS): 在本TODO正下方写唯一的时序寄存器块。
  // 使用always_ff @(posedge clk_i or negedge rst_ni)。复位时：
  // - read_state_q <= READ_SELECT；
  // - read_owner_q和last_grant_q选择确定的枚举值即可；owner在READ_SELECT中无语义。
  // 非复位时分别装载对应_d信号。不要在其他always块写这些_q寄存器。

  // TODO(AXI-ARB-ASSERT): 功能完成并接入top后，在本TODO正下方增加协议断言。
  // 最少检查：
  // 1. IFU和LSU的AR握手不能同周期同时发生。
  // 2. READ_WAIT_R期间read_owner_q保持稳定。
  // 3. 每个mem R握手之前必须存在一个已经完成的IFU或LSU AR握手。
  // 4. mem ARVALID && !ARREADY时，下一拍ARVALID和{ARADDR, ARPROT}保持稳定。
  // 5. mem RVALID只能被当前owner看到，非owner的RVALID必须为0。
  // 6. reset期间所有输出VALID为0。

endmodule
