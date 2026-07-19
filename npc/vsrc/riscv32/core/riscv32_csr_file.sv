module riscv32_csr_file
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  logic            csr_read_enable_i,
    input  logic [    11:0] csr_read_addr_i,
    output logic [XLEN-1:0] csr_read_data_o,
    output logic            csr_read_illegal_o,

    input logic            csr_write_valid_i,
    input logic [    11:0] csr_write_addr_i,
    input logic [XLEN-1:0] csr_write_data_i,

    input logic            trap_valid_i,
    input logic [XLEN-1:0] trap_pc_i,
    input logic [XLEN-1:0] trap_cause_i,
    input logic [XLEN-1:0] trap_tval_i,
    input logic            mret_valid_i,

    output logic [XLEN-1:0] mtvec_o,
    output logic [XLEN-1:0] mepc_o
);
  localparam logic [11:0] CSR_MVENDORID = 12'hF11;
  localparam logic [11:0] CSR_MARCHID   = 12'hF12;
  localparam logic [11:0] CSR_MSTATUS   = 12'h300;
  localparam logic [11:0] CSR_MIE       = 12'h304;
  localparam logic [11:0] CSR_MTVEC     = 12'h305;
  localparam logic [11:0] CSR_MSCRATCH  = 12'h340;
  localparam logic [11:0] CSR_MEPC      = 12'h341;
  localparam logic [11:0] CSR_MCAUSE    = 12'h342;
  localparam logic [11:0] CSR_MTVAL     = 12'h343;
  localparam logic [11:0] CSR_MIP       = 12'h344;
  localparam logic [11:0] CSR_MCYCLE    = 12'hB00;
  localparam logic [11:0] CSR_MCYCLEH   = 12'hB80;

  localparam logic [31:0] MVENDORID_VALUE = 32'h7973_7978;
  localparam logic [31:0] MARCHID_VALUE   = 32'h0150_BE98;

  logic [63:0] mcycle_q;
  logic [31:0] mstatus_q;
  logic [31:0] mie_q;
  logic [31:0] mtvec_q;
  logic [31:0] mscratch_q;
  logic [31:0] mepc_q;
  logic [31:0] mcause_q;
  logic [31:0] mtval_q;
  logic [31:0] mip_q;

  always_comb begin
    csr_read_data_o    = '0;
    csr_read_illegal_o = 1'b0;

    if (csr_read_enable_i) begin
      unique case (csr_read_addr_i)
        CSR_MVENDORID: csr_read_data_o = MVENDORID_VALUE;
        CSR_MARCHID:   csr_read_data_o = MARCHID_VALUE;
        CSR_MSTATUS:   csr_read_data_o = mstatus_q;
        CSR_MIE:       csr_read_data_o = mie_q;
        CSR_MTVEC:     csr_read_data_o = mtvec_q;
        CSR_MSCRATCH:  csr_read_data_o = mscratch_q;
        CSR_MEPC:      csr_read_data_o = mepc_q;
        CSR_MCAUSE:    csr_read_data_o = mcause_q;
        CSR_MTVAL:     csr_read_data_o = mtval_q;
        CSR_MIP:       csr_read_data_o = mip_q;
        CSR_MCYCLE:    csr_read_data_o = mcycle_q[31:0];
        CSR_MCYCLEH:   csr_read_data_o = mcycle_q[63:32];
        default: begin
          csr_read_data_o    = '0;
          csr_read_illegal_o = 1'b1;
        end
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mcycle_q   <= '0;
      mstatus_q  <= '0;
      mie_q      <= '0;
      mtvec_q    <= '0;
      mscratch_q <= '0;
      mepc_q     <= '0;
      mcause_q   <= '0;
      mtval_q    <= '0;
      mip_q      <= '0;
    end else begin
      if (csr_write_valid_i && (csr_write_addr_i == CSR_MCYCLE)) begin
        mcycle_q <= {mcycle_q[63:32], csr_write_data_i};
      end else if (csr_write_valid_i && (csr_write_addr_i == CSR_MCYCLEH)) begin
        mcycle_q <= {csr_write_data_i, mcycle_q[31:0]};
      end else begin
        mcycle_q <= mcycle_q + 64'd1;
      end

      if (trap_valid_i) begin
        mepc_q           <= trap_pc_i;
        mcause_q         <= trap_cause_i;
        mtval_q          <= trap_tval_i;
        mstatus_q[7]     <= mstatus_q[3];
        mstatus_q[3]     <= 1'b0;
        mstatus_q[12:11] <= PRIV_MODE_M;
      end else if (mret_valid_i) begin
        mstatus_q[3]     <= mstatus_q[7];
        mstatus_q[7]     <= 1'b1;
        mstatus_q[12:11] <= PRIV_MODE_U;
      end else if (csr_write_valid_i) begin
        unique case (csr_write_addr_i)
          CSR_MSTATUS:  mstatus_q <= csr_write_data_i;
          CSR_MIE:      mie_q <= csr_write_data_i;
          CSR_MTVEC:    mtvec_q <= csr_write_data_i;
          CSR_MSCRATCH: mscratch_q <= csr_write_data_i;
          CSR_MEPC:     mepc_q <= csr_write_data_i;
          CSR_MCAUSE:   mcause_q <= csr_write_data_i;
          CSR_MTVAL:    mtval_q <= csr_write_data_i;
          CSR_MIP:      mip_q <= csr_write_data_i;
          default:      ;
        endcase
      end
    end
  end

  assign mtvec_o = mtvec_q;
  assign mepc_o  = mepc_q;

  // NOTE(P4): add privilege/write-legality checks and expose faults as precise
  // completion metadata. NOTE(P6): only ROB-authorized commit writes this state.

endmodule
