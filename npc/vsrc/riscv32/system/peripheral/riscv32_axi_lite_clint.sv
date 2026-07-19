// Synthesizable AXI4-Lite CLINT peripheral.
//
// The current checkpoint implements only the read-only 64-bit mtime counter.
// mtimecmp, msip, and interrupt outputs are intentionally deferred until timer
// and software interrupts are introduced at the core commit boundary.
module riscv32_axi_lite_clint
  import riscv32_pkg::*;
#(
    parameter logic        [XLEN-1:0] CLINT_BASE_ADDR         = 32'ha000_0000,
    parameter int unsigned            CLINT_CLOCK_FREQ_HZ     = 100_000_000,
    parameter int unsigned            MTIME_INCREMENT_FREQ_HZ = 1_000_000
) (
    input logic clk_i,
    input logic rst_ni,

    input  axi_lite_addr_t clint_axi_ar_i,
    input  logic           clint_axi_arvalid_i,
    output logic           clint_axi_arready_o,
    output axi_lite_r_t    clint_axi_r_o,
    output logic           clint_axi_rvalid_o,
    input  logic           clint_axi_rready_i,

    input  axi_lite_addr_t clint_axi_aw_i,
    input  logic           clint_axi_awvalid_i,
    output logic           clint_axi_awready_o,
    input  axi_lite_w_t    clint_axi_w_i,
    input  logic           clint_axi_wvalid_i,
    output logic           clint_axi_wready_o,
    output axi_lite_b_t    clint_axi_b_o,
    output logic           clint_axi_bvalid_o,
    input  logic           clint_axi_bready_i
);

  localparam logic [XLEN-1:0] MTIME_LOW_REG_OFFSET  = 32'h0000_0048                          ;
  localparam logic [XLEN-1:0] MTIME_HIGH_REG_OFFSET = 32'h0000_004c                          ;
  localparam logic [XLEN-1:0] MTIME_LOW_REG_ADDR    = CLINT_BASE_ADDR + MTIME_LOW_REG_OFFSET ;
  localparam logic [XLEN-1:0] MTIME_HIGH_REG_ADDR   = CLINT_BASE_ADDR + MTIME_HIGH_REG_OFFSET;

  // MTIME_INCREMENT_PERIOD_CLINT_CLOCK_CYCLES is the fixed number of CLINT
  // input clock cycles per mtime increment. clint_clock_cycle_count_q records
  // the elapsed CLINT input clock cycles since the previous mtime increment.
  logic [63:0] mtime_q, mtime_d;
  localparam int unsigned MTIME_INCREMENT_PERIOD_CLINT_CLOCK_CYCLES =
      (MTIME_INCREMENT_FREQ_HZ > 0) ?
      (CLINT_CLOCK_FREQ_HZ / MTIME_INCREMENT_FREQ_HZ) : 1;
  localparam int unsigned CLINT_CLOCK_CYCLE_COUNT_WIDTH =
      (MTIME_INCREMENT_PERIOD_CLINT_CLOCK_CYCLES > 1) ?
      $clog2(
      MTIME_INCREMENT_PERIOD_CLINT_CLOCK_CYCLES
  ) : 1;
  logic [CLINT_CLOCK_CYCLE_COUNT_WIDTH-1:0] clint_clock_cycle_count_q;
  logic [CLINT_CLOCK_CYCLE_COUNT_WIDTH-1:0] clint_clock_cycle_count_d;

  initial begin : check_clint_parameters
    if (CLINT_CLOCK_FREQ_HZ == 0) begin
      $fatal(1, "CLINT_CLOCK_FREQ_HZ must be greater than zero");
    end else if (MTIME_INCREMENT_FREQ_HZ == 0) begin
      $fatal(1, "MTIME_INCREMENT_FREQ_HZ must be greater than zero");
    end else if (CLINT_CLOCK_FREQ_HZ < MTIME_INCREMENT_FREQ_HZ) begin
      $fatal(1, "CLINT_CLOCK_FREQ_HZ(%0d) must be >= MTIME_INCREMENT_FREQ_HZ(%0d)",
             CLINT_CLOCK_FREQ_HZ, MTIME_INCREMENT_FREQ_HZ);
    end else if ((CLINT_CLOCK_FREQ_HZ % MTIME_INCREMENT_FREQ_HZ) != 0) begin
      $fatal(1, "CLINT_CLOCK_FREQ_HZ(%0d) must be divisible by MTIME_INCREMENT_FREQ_HZ(%0d)",
             CLINT_CLOCK_FREQ_HZ, MTIME_INCREMENT_FREQ_HZ);
    end
  end

  // Generate one mtime increment after the configured CLINT clock-cycle period.
  always_comb begin
    mtime_d                   = mtime_q;
    clint_clock_cycle_count_d = clint_clock_cycle_count_q;

    if (MTIME_INCREMENT_PERIOD_CLINT_CLOCK_CYCLES == 1) begin
      clint_clock_cycle_count_d = '0;
      mtime_d                   = mtime_q + 64'd1;
    end else if (clint_clock_cycle_count_q ==
                 CLINT_CLOCK_CYCLE_COUNT_WIDTH'(
                     MTIME_INCREMENT_PERIOD_CLINT_CLOCK_CYCLES - 1
                 )) begin
      clint_clock_cycle_count_d = '0;
      mtime_d                   = mtime_q + 64'd1;
    end else begin
      clint_clock_cycle_count_d = clint_clock_cycle_count_q + 1'b1;
    end
  end

  // Keep the mtime-owned registers adjacent to their next-value logic.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mtime_q                   <= '0;
      clint_clock_cycle_count_q <= '0;
    end else begin
      mtime_q                   <= mtime_d;
      clint_clock_cycle_count_q <= clint_clock_cycle_count_d;
    end
  end

  // One read transaction may be outstanding. The registered response remains
  // stable while the master backpressures RVALID with RREADY low.
  typedef enum logic {
    AXI_READ_WAIT_ADDR,
    AXI_READ_RETURN_DATA
  } axi_read_state_e;

  axi_read_state_e        axi_read_state_q;
  axi_read_state_e        axi_read_state_d;
  axi_lite_r_t            clint_read_response_q;
  axi_lite_r_t            clint_read_response_d;
  logic                   clint_ar_handshake;
  logic                   clint_r_handshake;

  // The existing AM low-then-high sequence spans two AXI transactions. Retain
  // the low-read value so the later high read observes the same 64-bit mtime.
  logic            [63:0] mtime_read_snapshot_q;
  logic            [63:0] mtime_read_snapshot_d;
  logic                   mtime_read_snapshot_present_q;
  logic                   mtime_read_snapshot_present_d;
  logic                   unused_clint_axi_ar_prot;

  assign clint_ar_handshake = clint_axi_arvalid_i && clint_axi_arready_o;
  assign clint_r_handshake  = clint_axi_rvalid_o && clint_axi_rready_i;
  // This machine-mode-only CLINT checkpoint accepts every AXI protection class.
  assign unused_clint_axi_ar_prot = ^clint_axi_ar_i.prot;

  // Drive read-channel outputs only from registered state. In particular, the
  // registered R payload remains stable while RVALID is blocked by RREADY.
  always_comb begin
    clint_axi_arready_o = 1'b0;
    clint_axi_r_o       = clint_read_response_q;
    clint_axi_rvalid_o  = 1'b0;

    unique case (axi_read_state_q)
      AXI_READ_WAIT_ADDR: begin
        clint_axi_arready_o = 1'b1;
      end
      AXI_READ_RETURN_DATA: begin
        clint_axi_rvalid_o = 1'b1;
      end
      default: ;
    endcase
  end

  // Calculate every read-related _d signal in one block so each next-state
  // signal has exactly one combinational driver.
  always_comb begin
    axi_read_state_d              = axi_read_state_q;
    clint_read_response_d         = clint_read_response_q;
    mtime_read_snapshot_d         = mtime_read_snapshot_q;
    mtime_read_snapshot_present_d = mtime_read_snapshot_present_q;

    unique case (axi_read_state_q)
      AXI_READ_WAIT_ADDR: begin
        if (clint_ar_handshake) begin
          // Establish the default response before address selection. Therefore
          // every unlisted CLINT address returns zero with SLVERR.
          clint_read_response_d.data = '0;
          clint_read_response_d.resp = AXI_RESP_SLVERR;

          unique case (clint_axi_ar_i.addr)
            MTIME_LOW_REG_ADDR: begin
              // Preserve the complete value so a later high-word read belongs
              // to the same mtime observation as this low-word read.
              mtime_read_snapshot_d         = mtime_q;
              mtime_read_snapshot_present_d = 1'b1;
              clint_read_response_d.data    = mtime_q[31:0];
              clint_read_response_d.resp    = AXI_RESP_OKAY;
            end

            MTIME_HIGH_REG_ADDR: begin
              // Prefer the low-read snapshot. A standalone high-word read is
              // also legal and observes the current mtime value.
              if (mtime_read_snapshot_present_q) begin
                clint_read_response_d.data = mtime_read_snapshot_q[63:32];
              end else begin
                clint_read_response_d.data = mtime_q[63:32];
              end
              mtime_read_snapshot_present_d = 1'b0;
              clint_read_response_d.resp    = AXI_RESP_OKAY;
            end

            default: ;
          endcase

          // The response payload is ready; hold it until the R handshake.
          axi_read_state_d = AXI_READ_RETURN_DATA;
        end
      end

      AXI_READ_RETURN_DATA: begin
        if (clint_r_handshake) begin
          axi_read_state_d = AXI_READ_WAIT_ADDR;
        end
      end

      default: begin
        axi_read_state_d = AXI_READ_WAIT_ADDR;
      end
    endcase
  end

  // Keep the AXI read-channel registers adjacent to their next-state logic.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      axi_read_state_q              <= AXI_READ_WAIT_ADDR;
      clint_read_response_q         <= '0;
      mtime_read_snapshot_q         <= '0;
      mtime_read_snapshot_present_q <= 1'b0;
    end else begin
      axi_read_state_q              <= axi_read_state_d;
      clint_read_response_q         <= clint_read_response_d;
      mtime_read_snapshot_q         <= mtime_read_snapshot_d;
      mtime_read_snapshot_present_q <= mtime_read_snapshot_present_d;
    end
  end

  // AW and W are independent channels, so retain each payload until both have
  // arrived and one write response can be generated.
  typedef enum logic {
    AXI_WRITE_WAIT_ADDR_DATA,
    AXI_WRITE_RETURN_RESP
  } axi_write_state_e;
  axi_write_state_e axi_write_state_q, axi_write_state_d;
  axi_lite_b_t      clint_write_response_q, clint_write_response_d;
  axi_lite_addr_t   buffered_axi_write_addr_q, buffered_axi_write_addr_d;
  axi_lite_w_t      buffered_axi_write_data_q, buffered_axi_write_data_d;
  logic             buffered_axi_write_addr_present_q;
  logic             buffered_axi_write_addr_present_d;
  logic             buffered_axi_write_data_present_q;
  logic             buffered_axi_write_data_present_d;
  logic             clint_aw_handshake;
  logic             clint_w_handshake;
  logic             clint_b_handshake;

  assign clint_aw_handshake = clint_axi_awvalid_i && clint_axi_awready_o;
  assign clint_w_handshake  = clint_axi_wvalid_i  && clint_axi_wready_o;
  assign clint_b_handshake  = clint_axi_bvalid_o  && clint_axi_bready_i;

  always_comb begin
    clint_axi_awready_o = 1'b0;
    clint_axi_wready_o  = 1'b0;
    clint_axi_b_o       = clint_write_response_q;
    clint_axi_bvalid_o  = 1'b0;

    unique case (axi_write_state_q)
      AXI_WRITE_WAIT_ADDR_DATA: begin
        clint_axi_awready_o = !buffered_axi_write_addr_present_q;
        clint_axi_wready_o  = !buffered_axi_write_data_present_q;
      end
      AXI_WRITE_RETURN_RESP: begin
        clint_axi_bvalid_o = 1'b1;
      end
      default: ;
    endcase
  end

  // The "both present" condition must include both earlier buffered entries and
  // current-cycle handshakes; otherwise simultaneous AW/W incurs an extra cycle.
  always_comb begin
    axi_write_state_d                 = axi_write_state_q;
    clint_write_response_d            = clint_write_response_q;
    buffered_axi_write_addr_d         = buffered_axi_write_addr_q;
    buffered_axi_write_data_d         = buffered_axi_write_data_q;
    buffered_axi_write_addr_present_d = buffered_axi_write_addr_present_q;
    buffered_axi_write_data_present_d = buffered_axi_write_data_present_q;

    unique case (axi_write_state_q)
      AXI_WRITE_WAIT_ADDR_DATA: begin
        if (clint_aw_handshake) begin
          buffered_axi_write_addr_d         = clint_axi_aw_i;
          buffered_axi_write_addr_present_d = 1'b1;
        end
        if (clint_w_handshake) begin
          buffered_axi_write_data_d         = clint_axi_w_i;
          buffered_axi_write_data_present_d = 1'b1;
        end

        if ((buffered_axi_write_addr_present_q || clint_aw_handshake) &&
            (buffered_axi_write_data_present_q || clint_w_handshake)) begin
          clint_write_response_d.resp = AXI_RESP_SLVERR;
          axi_write_state_d           = AXI_WRITE_RETURN_RESP;
        end
      end

      AXI_WRITE_RETURN_RESP: begin
        if (clint_b_handshake) begin
          buffered_axi_write_addr_present_d = 1'b0;
          buffered_axi_write_data_present_d = 1'b0;
          axi_write_state_d                 = AXI_WRITE_WAIT_ADDR_DATA;
        end
      end
      default: begin
        axi_write_state_d                     = AXI_WRITE_WAIT_ADDR_DATA;
        buffered_axi_write_addr_present_d     = 1'b0;
        buffered_axi_write_data_present_d     = 1'b0;
      end
    endcase
  end

  // Keep the AXI write-channel registers adjacent to their next-state logic.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      axi_write_state_q                 <= AXI_WRITE_WAIT_ADDR_DATA;
      clint_write_response_q            <= '0;
      buffered_axi_write_addr_q         <= '0;
      buffered_axi_write_data_q         <= '0;
      buffered_axi_write_addr_present_q <= 1'b0;
      buffered_axi_write_data_present_q <= 1'b0;
    end else begin
      axi_write_state_q                 <= axi_write_state_d;
      clint_write_response_q            <= clint_write_response_d;
      buffered_axi_write_addr_q         <= buffered_axi_write_addr_d;
      buffered_axi_write_data_q         <= buffered_axi_write_data_d;
      buffered_axi_write_addr_present_q <= buffered_axi_write_addr_present_d;
      buffered_axi_write_data_present_q <= buffered_axi_write_data_present_d;
    end
  end

  // TODO(CLINT-10-ASSERTIONS-LATER): This is not required to connect the
  // current CLINT. After directed functional tests pass, introduce assertion
  // bookkeeping and then check the following protocol properties:
  // 1. R payload remains stable while RVALID && !RREADY.
  // 2. B response remains stable while BVALID && !BREADY.
  // 3. One accepted AR produces exactly one R response.
  // 4. One accepted AW plus one accepted W produces exactly one B response.
  // 5. mtime never changes because of an AXI write.
  // 6. AXI response-valid outputs remain low during reset.
  // 7. Unsupported CLINT offsets return SLVERR, never OKAY.

  // NOTE(CLINT-INTERRUPTS): Do not add interrupt wiring in this checkpoint.
  // When timer/software interrupts are introduced, add mtimecmp and msip here,
  // then expose explicitly named machine_timer_irq_o and
  // machine_software_irq_o ports. Those signals enter the core's interrupt/trap
  // boundary; this peripheral must never write core CSRs or redirect the PC.

endmodule
