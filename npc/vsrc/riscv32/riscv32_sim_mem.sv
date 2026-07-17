// Simulation-only AXI4-Lite memory slave. IFU read, LSU read, and LSU write use
// independent single-outstanding state machines and share the existing DPI backend.
module riscv32_sim_mem
  import riscv32_pkg::*;
#(
    parameter int unsigned IFU_READ_LATENCY  = 1,
    parameter int unsigned LSU_READ_LATENCY  = 1,
    parameter int unsigned LSU_WRITE_LATENCY = 1,
    parameter int unsigned RANDOM_LATENCY_MAX = 20
) (
    input logic clk_i,
    input logic rst_ni,

    input  axi_lite_addr_t ifu_axi_ar_i,
    input  logic           ifu_axi_arvalid_i,
    output logic           ifu_axi_arready_o,
    output axi_lite_r_t    ifu_axi_r_o,
    output logic           ifu_axi_rvalid_o,
    input  logic           ifu_axi_rready_i,

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
    input  logic           lsu_axi_bready_i
);

  // DPI remains in this simulation adapter and does not enter the CPU core.
  import "DPI-C" function int pmem_read(input int raddr);
  import "DPI-C" function int pmem_read_data(
    input int raddr,
    input int len
  );
  import "DPI-C" function void pmem_write(
    input int  addr,
    input int  wdata,
    input byte wmask
  );

  // Each port accepts one outstanding transaction. Response latency counts from the
  // request handshake cycle; latency=1 preserves the original next-cycle response.
  // The registered response payload remains stable until its response handshake.
  localparam int unsigned IFU_MAX_LATENCY = (IFU_READ_LATENCY > RANDOM_LATENCY_MAX) ?
                                               IFU_READ_LATENCY : RANDOM_LATENCY_MAX;
  localparam int unsigned LSU_READ_MAX_LATENCY = (LSU_READ_LATENCY > RANDOM_LATENCY_MAX) ?
                                                    LSU_READ_LATENCY : RANDOM_LATENCY_MAX;
  localparam int unsigned LSU_WRITE_MAX_LATENCY = (LSU_WRITE_LATENCY > RANDOM_LATENCY_MAX) ?
                                                     LSU_WRITE_LATENCY : RANDOM_LATENCY_MAX;
  localparam int unsigned IFU_DELAY_W = (IFU_MAX_LATENCY > 1) ? $clog2(IFU_MAX_LATENCY) : 1;
  localparam int unsigned LSU_READ_DELAY_W = (LSU_READ_MAX_LATENCY > 1) ?
                                                $clog2(LSU_READ_MAX_LATENCY) : 1;
  localparam int unsigned LSU_WRITE_DELAY_W = (LSU_WRITE_MAX_LATENCY > 1) ?
                                                 $clog2(LSU_WRITE_MAX_LATENCY) : 1;
  typedef enum logic [1:0] {
    READ_IDLE,
    READ_WAIT,
    READ_RESP
  } read_state_e;
  typedef enum logic [1:0] {
    WRITE_COLLECT,
    WRITE_WAIT,
    WRITE_RESP
  } write_state_e;
  read_state_e ifu_read_state_q, ifu_read_state_d;
  read_state_e lsu_read_state_q, lsu_read_state_d;
  write_state_e lsu_write_state_q, lsu_write_state_d;
  axi_lite_r_t ifu_r_q;
  axi_lite_r_t lsu_r_q;
  axi_lite_b_t lsu_b_q;
  axi_lite_addr_t lsu_aw_q, lsu_aw_d;
  axi_lite_w_t lsu_w_q, lsu_w_d;
  axi_lite_addr_t active_lsu_aw;
  axi_lite_w_t    active_lsu_w;
  logic [IFU_DELAY_W-1:0] ifu_delay_q, ifu_delay_d;
  logic [LSU_READ_DELAY_W-1:0] lsu_read_delay_q, lsu_read_delay_d;
  logic [LSU_WRITE_DELAY_W-1:0] lsu_write_delay_q, lsu_write_delay_d;
  logic [15:0] ifu_lfsr_q;
  logic [15:0] lsu_read_lfsr_q;
  logic [15:0] lsu_write_lfsr_q;
  logic        random_latency_enable;
  int unsigned lfsr_seed;
  int unsigned ifu_selected_latency;
  int unsigned lsu_read_selected_latency;
  int unsigned lsu_write_selected_latency;
  logic lsu_aw_handshake_occurred_q, lsu_aw_handshake_occurred_d;
  logic lsu_w_handshake_occurred_q, lsu_w_handshake_occurred_d;
  logic ifu_ar_handshake, ifu_r_handshake;
  logic lsu_ar_handshake, lsu_r_handshake;
  logic lsu_aw_handshake, lsu_w_handshake, lsu_b_handshake;
  logic lsu_write_request_complete;

  function automatic logic [15:0] lfsr_next(input logic [15:0] value);
    lfsr_next = {value[14:0], value[15] ^ value[13] ^ value[12] ^ value[10]};
  endfunction

  function automatic int unsigned select_latency(
    input logic [15:0] value,
    input int unsigned fixed_latency
  );
    if (random_latency_enable) begin
      select_latency = 1 + (32'($unsigned(value)) % RANDOM_LATENCY_MAX);
    end else begin
      select_latency = fixed_latency;
    end
  endfunction

  always_comb begin
    ifu_selected_latency      = select_latency(ifu_lfsr_q, IFU_READ_LATENCY);
    lsu_read_selected_latency = select_latency(lsu_read_lfsr_q, LSU_READ_LATENCY);
    lsu_write_selected_latency = select_latency(lsu_write_lfsr_q, LSU_WRITE_LATENCY);
  end

  assign ifu_ar_handshake = ifu_axi_arvalid_i && ifu_axi_arready_o;
  assign ifu_r_handshake  = ifu_axi_rvalid_o && ifu_axi_rready_i;
  assign lsu_ar_handshake = lsu_axi_arvalid_i && lsu_axi_arready_o;
  assign lsu_r_handshake  = lsu_axi_rvalid_o && lsu_axi_rready_i;
  assign lsu_aw_handshake = lsu_axi_awvalid_i && lsu_axi_awready_o;
  assign lsu_w_handshake  = lsu_axi_wvalid_i && lsu_axi_wready_o;
  assign lsu_b_handshake  = lsu_axi_bvalid_o && lsu_axi_bready_i;
  always_comb begin
    active_lsu_aw = lsu_aw_handshake ? lsu_axi_aw_i : lsu_aw_q;
    active_lsu_w  = lsu_w_handshake ? lsu_axi_w_i : lsu_w_q;

    lsu_write_request_complete =
        (lsu_write_state_q == WRITE_COLLECT) &&
        (lsu_aw_handshake_occurred_q || lsu_aw_handshake) &&
        (lsu_w_handshake_occurred_q  || lsu_w_handshake);
  end
  initial begin
    if (IFU_READ_LATENCY == 0) $fatal(1, "IFU_READ_LATENCY must be >= 1");
    if (LSU_READ_LATENCY == 0) $fatal(1, "LSU_READ_LATENCY must be >= 1");
    if (LSU_WRITE_LATENCY == 0) $fatal(1, "LSU_WRITE_LATENCY must be >= 1");
    if (RANDOM_LATENCY_MAX == 0) $fatal(1, "RANDOM_LATENCY_MAX must be >= 1");

    random_latency_enable = $test$plusargs("axi_random_latency");
    if (!$value$plusargs("axi_lfsr_seed=%d", lfsr_seed)) begin
      lfsr_seed = 32'h1;
    end
    if (lfsr_seed[15:0] == '0) begin
      $fatal(1, "axi_lfsr_seed must be non-zero");
    end
    if (random_latency_enable) begin
      $display("AXI sim memory random latency enabled: seed=%0d max=%0d",
               lfsr_seed, RANDOM_LATENCY_MAX);
    end
  end

  always_comb begin
    ifu_axi_arready_o = 1'b0;
    ifu_axi_r_o       = ifu_r_q;
    ifu_axi_rvalid_o  = 1'b0;

    if (rst_ni) begin
      unique case (ifu_read_state_q)
        READ_IDLE: ifu_axi_arready_o = !random_latency_enable || ifu_lfsr_q[0];
        READ_RESP: ifu_axi_rvalid_o = 1'b1;
        default:   ;
      endcase
    end
  end
  always_comb begin
    ifu_read_state_d = ifu_read_state_q;
    ifu_delay_d      = ifu_delay_q;

    unique case (ifu_read_state_q)
      READ_IDLE: begin
        if (ifu_ar_handshake) begin
          if (ifu_selected_latency == 1) begin
            ifu_read_state_d = READ_RESP;
          end else begin
            ifu_delay_d      = IFU_DELAY_W'(ifu_selected_latency - 1);
            ifu_read_state_d = READ_WAIT;
          end
        end
      end

      READ_WAIT: begin
        if (ifu_delay_q == IFU_DELAY_W'(1)) begin
          ifu_delay_d      = '0;
          ifu_read_state_d = READ_RESP;
        end else begin
          ifu_delay_d = ifu_delay_q - IFU_DELAY_W'(1);
        end
      end

      READ_RESP: begin
        if (ifu_r_handshake) begin
          ifu_read_state_d = READ_IDLE;
        end
      end

      default: begin
        ifu_read_state_d = READ_IDLE;
        ifu_delay_d      = '0;
      end
    endcase
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ifu_read_state_q <= READ_IDLE;
      ifu_delay_q      <= '0;
      ifu_r_q          <= '0;
      ifu_lfsr_q       <= lfsr_seed[15:0];
    end else begin
      ifu_read_state_q <= ifu_read_state_d;
      ifu_delay_q      <= ifu_delay_d;

      if (random_latency_enable) begin
        ifu_lfsr_q <= lfsr_next(ifu_lfsr_q);
      end

      if (ifu_ar_handshake) begin
        ifu_r_q.data <= pmem_read(int'(ifu_axi_ar_i.addr));
        ifu_r_q.resp <= AXI_RESP_OKAY;
      end
    end
  end
  always_comb begin
    lsu_axi_arready_o = 1'b0;
    lsu_axi_r_o       = lsu_r_q;
    lsu_axi_rvalid_o  = 1'b0;

    if (rst_ni) begin
      unique case (lsu_read_state_q)
        READ_IDLE: lsu_axi_arready_o = !random_latency_enable || lsu_read_lfsr_q[0];
        READ_RESP: lsu_axi_rvalid_o = 1'b1;
        default:   ;
      endcase
    end
  end
  always_comb begin
    lsu_read_state_d = lsu_read_state_q;
    lsu_read_delay_d = lsu_read_delay_q;

    unique case (lsu_read_state_q)
      READ_IDLE: begin
        if (lsu_ar_handshake) begin
          if (lsu_read_selected_latency == 1) begin
            lsu_read_state_d = READ_RESP;
          end else begin
            lsu_read_delay_d = LSU_READ_DELAY_W'(lsu_read_selected_latency - 1);
            lsu_read_state_d = READ_WAIT;
          end
        end
      end

      READ_WAIT: begin
        if (lsu_read_delay_q == LSU_READ_DELAY_W'(1)) begin
          lsu_read_delay_d = '0;
          lsu_read_state_d = READ_RESP;
        end else begin
          lsu_read_delay_d = lsu_read_delay_q - LSU_READ_DELAY_W'(1);
        end
      end

      READ_RESP: begin
        if (lsu_r_handshake) begin
          lsu_read_state_d = READ_IDLE;
        end
      end

      default: begin
        lsu_read_state_d = READ_IDLE;
        lsu_read_delay_d = '0;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_read_state_q <= READ_IDLE;
      lsu_read_delay_q <= '0;
      lsu_r_q          <= '0;
      lsu_read_lfsr_q  <= (lfsr_seed[15:0] ^ 16'h1d0f) | 16'h1;
    end else begin
      lsu_read_state_q <= lsu_read_state_d;
      lsu_read_delay_q <= lsu_read_delay_d;

      if (random_latency_enable) begin
        lsu_read_lfsr_q <= lfsr_next(lsu_read_lfsr_q);
      end

      if (lsu_ar_handshake) begin
        lsu_r_q.data <= pmem_read_data(int'(lsu_axi_ar_i.addr), 4);
        lsu_r_q.resp <= AXI_RESP_OKAY;
      end
    end
  end
  // len固定为4，因为AXI4-Lite接口没有AxSIZE，LSU随后根据原始effective_addr和mem_size
  // 选择byte/halfword。RVALID保持期间不能再次调用pmem_read_data。

  // AW and W are accepted independently. The saved channel value is paired with
  // a same-cycle handshake value so either channel can arrive first.
  always_comb begin
    lsu_axi_awready_o = 1'b0;
    lsu_axi_wready_o  = 1'b0;
    lsu_axi_b_o       = lsu_b_q;
    lsu_axi_bvalid_o  = 1'b0;

    if (rst_ni) begin
      unique case (lsu_write_state_q)
        WRITE_COLLECT: begin
          lsu_axi_awready_o = !lsu_aw_handshake_occurred_q &&
                              (!random_latency_enable || lsu_write_lfsr_q[0]);
          lsu_axi_wready_o  = !lsu_w_handshake_occurred_q &&
                              (!random_latency_enable || lsu_write_lfsr_q[5]);
        end
        WRITE_RESP: begin
          lsu_axi_bvalid_o = 1'b1;
        end
        default: ;
      endcase
    end
  end
  always_comb begin
    lsu_write_state_d           = lsu_write_state_q;
    lsu_write_delay_d           = lsu_write_delay_q;
    lsu_aw_d                    = lsu_aw_q;
    lsu_w_d                     = lsu_w_q;
    lsu_aw_handshake_occurred_d = lsu_aw_handshake_occurred_q;
    lsu_w_handshake_occurred_d  = lsu_w_handshake_occurred_q;

    unique case (lsu_write_state_q)
      WRITE_COLLECT: begin
        if (lsu_aw_handshake) begin
          lsu_aw_d                    = lsu_axi_aw_i;
          lsu_aw_handshake_occurred_d = 1'b1;
        end
        if (lsu_w_handshake) begin
          lsu_w_d                    = lsu_axi_w_i;
          lsu_w_handshake_occurred_d = 1'b1;
        end

        if (lsu_write_request_complete) begin
          if (lsu_write_selected_latency == 1) begin
            lsu_write_state_d = WRITE_RESP;
          end else begin
            lsu_write_delay_d = LSU_WRITE_DELAY_W'(lsu_write_selected_latency - 1);
            lsu_write_state_d = WRITE_WAIT;
          end
        end
      end

      WRITE_WAIT: begin
        if (lsu_write_delay_q == LSU_WRITE_DELAY_W'(1)) begin
          lsu_write_delay_d = '0;
          lsu_write_state_d = WRITE_RESP;
        end else begin
          lsu_write_delay_d = lsu_write_delay_q - LSU_WRITE_DELAY_W'(1);
        end
      end

      WRITE_RESP: begin
        if (lsu_b_handshake) begin
          lsu_aw_handshake_occurred_d = 1'b0;
          lsu_w_handshake_occurred_d  = 1'b0;
          lsu_write_state_d           = WRITE_COLLECT;
        end
      end

      default: begin
        lsu_write_state_d           = WRITE_COLLECT;
        lsu_write_delay_d           = '0;
        lsu_aw_handshake_occurred_d = 1'b0;
        lsu_w_handshake_occurred_d  = 1'b0;
      end
    endcase
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_write_state_q           <= WRITE_COLLECT;
      lsu_write_delay_q           <= '0;
      lsu_aw_q                    <= '0;
      lsu_w_q                     <= '0;
      lsu_b_q                     <= '0;
      lsu_aw_handshake_occurred_q <= 1'b0;
      lsu_w_handshake_occurred_q  <= 1'b0;
      lsu_write_lfsr_q            <= (lfsr_seed[15:0] ^ 16'hb400) | 16'h1;
    end else begin
      lsu_write_state_q           <= lsu_write_state_d;
      lsu_write_delay_q           <= lsu_write_delay_d;
      lsu_aw_q                    <= lsu_aw_d;
      lsu_w_q                     <= lsu_w_d;
      lsu_aw_handshake_occurred_q <= lsu_aw_handshake_occurred_d;
      lsu_w_handshake_occurred_q  <= lsu_w_handshake_occurred_d;

      if (random_latency_enable) begin
        lsu_write_lfsr_q <= lfsr_next(lsu_write_lfsr_q);
      end

      if (lsu_write_request_complete) begin
        pmem_write(int'(active_lsu_aw.addr), int'(active_lsu_w.data), byte'(active_lsu_w.strb));
        lsu_b_q.resp <= AXI_RESP_OKAY;
      end
    end
  end
  // TODO(AXI-MEM-CONCURRENCY): 当前CPU的单条LSU操作不会同时发load和store，但IFU取指可与
  // LSU数据访问并行。仿真DPI后端允许这种逻辑并行；若以后映射到单端口SRAM，需要在本模块
  // 内或独立adapter中仲裁实际backend access，同时保持已经接受的AXI事务不会丢失。
  //
  // 同地址同周期读写的返回值由具体memory实现决定，不能假设所有SRAM/FPGA BRAM一致。
  // 若系统需要确定行为，应在backend仲裁中明确read-first、write-first或禁止并发，并通过
  // assertion检查。该策略不属于AXI握手协议本身。
  //
  // TODO(AXI-MEM-ASSERT): slave侧加入协议断言：
  // - reset期间RVALID/BVALID为0。
  // - RVALID && !RREADY时RDATA/RRESP稳定；BVALID && !BREADY时BRESP稳定。
  // - 每个R之前恰好有一个AR；每个B之前恰好有一个AW和一个W。
  // - AW/W可按任意顺序握手，且一次事务不能重复接收第二个AW或W。
  // - READY/VALID逻辑不存在AXI输入到AXI输出的组合路径。

  p_ifu_arprot_known :
  assert property (@(posedge clk_i) ifu_ar_handshake |-> !$isunknown(ifu_axi_ar_i.prot))
  else $error("IFU ARPROT contains X at handshake");

  p_lsu_arprot_known :
  assert property (@(posedge clk_i) lsu_ar_handshake |-> !$isunknown(lsu_axi_ar_i.prot))
  else $error("LSU ARPROT contains X at handshake");

  p_lsu_awprot_known :
  assert property (@(posedge clk_i) lsu_aw_handshake |-> !$isunknown(lsu_axi_aw_i.prot))
  else $error("LSU AWPROT contains X at handshake");

  p_lsu_active_awprot_known :
  assert property (
    @(posedge clk_i) lsu_write_request_complete |-> !$isunknown(active_lsu_aw.prot)
  )
  else $error("Stored LSU AWPROT contains X when write request completes");



endmodule
