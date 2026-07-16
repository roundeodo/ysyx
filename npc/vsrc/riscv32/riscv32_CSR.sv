module riscv32_CSR
  import riscv32_pkg::*;
#(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 32
) (
    input logic clk,
    input logic rst,

    input logic                     i_csr_ren,
    input logic                     i_csr_wren,
    input logic    [ADDR_WIDTH-1:0] i_csr_addr,
    input csr_op_t                  i_csr_op,
    input logic    [DATA_WIDTH-1:0] i_csr_src,

    input logic                  i_trap_valid,
    input logic [DATA_WIDTH-1:0] i_trap_mepc,
    input logic [DATA_WIDTH-1:0] i_trap_mcause,

    output logic [DATA_WIDTH-1:0] o_csr_mtvec,
    output logic [DATA_WIDTH-1:0] o_csr_mepc,

    output logic [DATA_WIDTH-1:0] o_csr_rdata,
    output logic                  o_csr_illegal
);

  localparam logic [ADDR_WIDTH-1:0] CSR_MVENDORID = 12'hF11;
  localparam logic [ADDR_WIDTH-1:0] CSR_MARCHID   = 12'hF12;
  localparam logic [ADDR_WIDTH-1:0] CSR_MSTATUS   = 12'h300;
  localparam logic [ADDR_WIDTH-1:0] CSR_MIE       = 12'h304;
  localparam logic [ADDR_WIDTH-1:0] CSR_MTVEC     = 12'h305;
  localparam logic [ADDR_WIDTH-1:0] CSR_MSCRATCH  = 12'h340;
  localparam logic [ADDR_WIDTH-1:0] CSR_MEPC      = 12'h341;
  localparam logic [ADDR_WIDTH-1:0] CSR_MCAUSE    = 12'h342;
  localparam logic [ADDR_WIDTH-1:0] CSR_MIP       = 12'h344;
  localparam logic [ADDR_WIDTH-1:0] CSR_MCYCLE    = 12'hB00;
  localparam logic [ADDR_WIDTH-1:0] CSR_MCYCLEH   = 12'hB80;

  localparam logic [31:0] MVENDORID_VALUE = 32'h7973_7978;  // "ysyx"
  localparam logic [31:0] MARCHID_VALUE   = 32'h0150_be98;  // 22068888

  logic [63:0] mcycle;
  logic [31:0] mstatus;
  logic [31:0] mie;
  logic [31:0] mtvec;
  logic [31:0] mscratch;
  logic [31:0] mepc;
  logic [31:0] mcause;
  logic [31:0] mip;

  logic [DATA_WIDTH-1:0] csr_wdata;
  //operation
  always_comb begin
    case (i_csr_op)
      CSR_OP_RW: csr_wdata = i_csr_src;
      CSR_OP_RS: csr_wdata = o_csr_rdata | i_csr_src;
      CSR_OP_RC: csr_wdata = o_csr_rdata & ~i_csr_src;
      default:   csr_wdata = {DATA_WIDTH{1'b0}};
    endcase
  end


  //read
  always_comb begin
    o_csr_rdata   = 32'b0;
    o_csr_illegal = 1'b0;

    if (i_csr_ren) begin
      case (i_csr_addr)
        CSR_MVENDORID: o_csr_rdata = MVENDORID_VALUE;
        CSR_MARCHID:   o_csr_rdata = MARCHID_VALUE;

        CSR_MSTATUS:  o_csr_rdata = mstatus;
        CSR_MIE:      o_csr_rdata = mie;
        CSR_MTVEC:    o_csr_rdata = mtvec;
        CSR_MSCRATCH: o_csr_rdata = mscratch;
        CSR_MEPC:     o_csr_rdata = mepc;
        CSR_MCAUSE:   o_csr_rdata = mcause;
        CSR_MIP:      o_csr_rdata = mip;

        CSR_MCYCLE:  o_csr_rdata = mcycle[31:0];
        CSR_MCYCLEH: o_csr_rdata = mcycle[63:32];

        default: begin
          o_csr_rdata   = 32'b0;
          o_csr_illegal = 1'b1;
        end
      endcase
    end
  end

  //write
  always_ff @(posedge clk) begin
    if (rst) begin
      mcycle   <= 64'b0;
      mstatus  <= 32'b0;
      mie      <= 32'b0;
      mtvec    <= 32'b0;
      mscratch <= 32'b0;
      mepc     <= 32'b0;
      mcause   <= 32'b0;
      mip      <= 32'b0;
    end else begin
      mcycle <= mcycle + 1;
      if (i_trap_valid) begin
        mepc   <= i_trap_mepc;
        mcause <= i_trap_mcause;
      end else if (i_csr_wren) begin
        case (i_csr_addr)
          CSR_MSTATUS:  mstatus <= csr_wdata;
          CSR_MIE:      mie <= csr_wdata;
          CSR_MTVEC:    mtvec <= csr_wdata;
          CSR_MSCRATCH: mscratch <= csr_wdata;
          CSR_MEPC:     mepc <= csr_wdata;
          CSR_MCAUSE:   mcause <= csr_wdata;
          CSR_MIP:      mip <= csr_wdata;
          CSR_MCYCLE:   mcycle[31:0] <= csr_wdata;
          CSR_MCYCLEH:  mcycle[63:32] <= csr_wdata;
          default:      ;
        endcase
      end
    end
  end

  assign o_csr_mtvec = mtvec;
  assign o_csr_mepc  = mepc;

endmodule
