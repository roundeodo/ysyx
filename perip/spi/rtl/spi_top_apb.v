// define this macro to enable fast behavior simulation
// for flash by skipping SPI transfers
`define FAST_FLASH
module spi_top_apb #(
    parameter flash_addr_start = 32'h30000000,
    parameter flash_addr_end   = 32'h3fffffff,
    parameter spi_ss_num       = 8
) (
    input         clock,
    input         reset,
    input  [31:0] in_paddr,
    input         in_psel,
    input         in_penable,
    input  [ 2:0] in_pprot,
    input         in_pwrite,
    input  [31:0] in_pwdata,
    input  [ 3:0] in_pstrb,
    output        in_pready,
    output [31:0] in_prdata,
    output        in_pslverr,

    output                  spi_sck,
    output [spi_ss_num-1:0] spi_ss,
    output                  spi_mosi,
    input                   spi_miso,
    output                  spi_irq_out
);

`ifdef FAST_FLASH

  wire [31:0] data;
  parameter invalid_cmd = 8'h0;
  flash_cmd flash_cmd_i (
      .clock(clock),
      .valid(in_psel && !in_penable),
      .cmd  (in_pwrite ? invalid_cmd : 8'h03),
      .addr ({8'b0, in_paddr[23:2], 2'b0}),
      .data (data)
  );
  assign spi_sck     = 1'b0;
  assign spi_ss      = 8'b0;
  assign spi_mosi    = 1'b1;
  assign spi_irq_out = 1'b0;
  assign in_pslverr  = 1'b0;
  assign in_pready   = in_penable && in_psel && !in_pwrite;
  assign in_prdata   = data[31:0];

`else

  localparam [4:0] SPI_TXRX0_ADDR   = 5'h00;
  localparam [4:0] SPI_TXRX1_ADDR   = 5'h04;
  localparam [4:0] SPI_CTRL_ADDR    = 5'h10;
  localparam [4:0] SPI_DIVIDER_ADDR = 5'h14;
  localparam [4:0] SPI_SS_ADDR      = 5'h18;

  localparam [31:0] SPI_CONTROL_CONFIG = 32'h0000_2440;
  localparam [31:0] SPI_CONTROL_START  = 32'h0000_2540;

  localparam [3:0] XIP_WAIT_REQUEST       = 4'd0;
  localparam [3:0] XIP_WRITE_TXRX0        = 4'd1;
  localparam [3:0] XIP_WRITE_TXRX1        = 4'd2;
  localparam [3:0] XIP_WRITE_DIVIDER      = 4'd3;
  localparam [3:0] XIP_WRITE_SLAVE_SELECT = 4'd4;
  localparam [3:0] XIP_WRITE_CONTROL      = 4'd5;
  localparam [3:0] XIP_START_TRANSFER     = 4'd6;
  localparam [3:0] XIP_READ_CONTROL       = 4'd7;
  localparam [3:0] XIP_READ_DATA          = 4'd8;
  localparam [3:0] XIP_RETURN_RESPONSE    = 4'd9;

  wire spi_register_address_range;
  wire flash_xip_address_range;
  wire flash_xip_read_request;
  wire flash_xip_write_access;
  wire [31:0] flash_xip_byte_offset;

  reg [3:0] xip_state_q;
  reg [3:0] xip_state_d;

  reg [23:0] flash_read_byte_offset_q;
  reg [23:0] flash_read_byte_offset_d;

  reg [31:0] flash_xip_read_data_q;
  reg [31:0] flash_xip_read_data_d;

  reg [4:0]  spi_wb_addr;
  reg [31:0] spi_wb_write_data;
  reg [3:0]  spi_wb_byte_enable;
  reg        spi_wb_write_enable;
  reg        spi_wb_strobe;
  reg        spi_wb_cycle;

  wire [31:0] spi_wb_read_data;
  wire        spi_wb_ack;
  wire        spi_wb_error;

  reg        apb_response_ready;
  reg [31:0] apb_response_read_data;
  reg        apb_response_error;

  assign spi_register_address_range =
      (in_paddr >= 32'h1000_1000) &&
      (in_paddr <= 32'h1000_1fff);

  assign flash_xip_address_range =
      (in_paddr >= flash_addr_start) &&
      (in_paddr <= flash_addr_end);

  assign flash_xip_byte_offset = in_paddr - flash_addr_start;

  assign flash_xip_read_request =
      in_psel && !in_penable && !in_pwrite && flash_xip_address_range;

  assign flash_xip_write_access =
      in_psel && in_penable && in_pwrite && flash_xip_address_range;

  assign in_pready  = apb_response_ready;
  assign in_prdata  = apb_response_read_data;
  assign in_pslverr = apb_response_error;

  function [31:0] byte_swap32;
    input [31:0] value;
    begin
      byte_swap32 = {
        value[7:0],
        value[15:8],
        value[23:16],
        value[31:24]
      };
    end
  endfunction

  always @(posedge clock or posedge reset) begin
    if (reset)
      xip_state_q <= XIP_WAIT_REQUEST;
    else
      xip_state_q <= xip_state_d;
  end

  always @(posedge clock or posedge reset) begin
    if (reset)
      flash_read_byte_offset_q <= 24'b0;
    else
      flash_read_byte_offset_q <= flash_read_byte_offset_d;
  end

  always @(posedge clock or posedge reset) begin
    if (reset)
      flash_xip_read_data_q <= 32'b0;
    else
      flash_xip_read_data_q <= flash_xip_read_data_d;
  end

  always @(*) begin
    xip_state_d              = xip_state_q;
    flash_read_byte_offset_d = flash_read_byte_offset_q;
    flash_xip_read_data_d    = flash_xip_read_data_q;

    case (xip_state_q)
      XIP_WAIT_REQUEST: begin
        if (flash_xip_read_request) begin
          flash_read_byte_offset_d =
              {flash_xip_byte_offset[23:2], 2'b00};
          xip_state_d = XIP_WRITE_TXRX0;
        end
      end

      XIP_WRITE_TXRX0:
        if (spi_wb_ack)
          xip_state_d = XIP_WRITE_TXRX1;

      XIP_WRITE_TXRX1:
        if (spi_wb_ack)
          xip_state_d = XIP_WRITE_DIVIDER;

      XIP_WRITE_DIVIDER:
        if (spi_wb_ack)
          xip_state_d = XIP_WRITE_SLAVE_SELECT;

      XIP_WRITE_SLAVE_SELECT:
        if (spi_wb_ack)
          xip_state_d = XIP_WRITE_CONTROL;

      XIP_WRITE_CONTROL:
        if (spi_wb_ack)
          xip_state_d = XIP_START_TRANSFER;

      XIP_START_TRANSFER:
        if (spi_wb_ack)
          xip_state_d = XIP_READ_CONTROL;

      XIP_READ_CONTROL: begin
        if (spi_wb_ack && !spi_wb_read_data[8])
          xip_state_d = XIP_READ_DATA;
      end

      XIP_READ_DATA: begin
        if (spi_wb_ack) begin
          flash_xip_read_data_d = byte_swap32(spi_wb_read_data);
          xip_state_d           = XIP_RETURN_RESPONSE;
        end
      end

      XIP_RETURN_RESPONSE: begin
        if (in_psel && in_penable)
          xip_state_d = XIP_WAIT_REQUEST;
      end

      default: begin
        xip_state_d = XIP_WAIT_REQUEST;
      end
    endcase
  end

  always @(*) begin
    spi_wb_addr         = 5'b0;
    spi_wb_write_data   = 32'b0;
    spi_wb_byte_enable  = 4'hf;
    spi_wb_write_enable = 1'b0;
    spi_wb_strobe       = 1'b0;
    spi_wb_cycle        = 1'b0;

    apb_response_ready     = 1'b0;
    apb_response_read_data = 32'b0;
    apb_response_error     = 1'b0;

    case (xip_state_q)
      XIP_WAIT_REQUEST: begin
        if (spi_register_address_range) begin
          spi_wb_addr         = in_paddr[4:0];
          spi_wb_write_data   = in_pwdata;
          spi_wb_byte_enable  = in_pstrb;
          spi_wb_write_enable = in_pwrite;
          spi_wb_strobe       = in_psel;
          spi_wb_cycle        = in_penable;

          apb_response_ready     = spi_wb_ack;
          apb_response_read_data = spi_wb_read_data;
          apb_response_error     = spi_wb_error;
        end else if (flash_xip_address_range) begin
          if (flash_xip_write_access) begin
            apb_response_ready = 1'b1;
            apb_response_error = 1'b1;
          end
        end else if (in_psel && in_penable) begin
          apb_response_ready = 1'b1;
          apb_response_error = 1'b1;
        end
      end

      XIP_WRITE_TXRX0: begin
        spi_wb_addr         = SPI_TXRX0_ADDR;
        spi_wb_write_data   = 32'b0;
        spi_wb_write_enable = 1'b1;
        spi_wb_strobe       = 1'b1;
        spi_wb_cycle        = 1'b1;
      end

      XIP_WRITE_TXRX1: begin
        spi_wb_addr         = SPI_TXRX1_ADDR;
        spi_wb_write_data   = {8'h03, flash_read_byte_offset_q};
        spi_wb_write_enable = 1'b1;
        spi_wb_strobe       = 1'b1;
        spi_wb_cycle        = 1'b1;
      end

      XIP_WRITE_DIVIDER: begin
        spi_wb_addr         = SPI_DIVIDER_ADDR;
        spi_wb_write_data   = 32'd2;
        spi_wb_write_enable = 1'b1;
        spi_wb_strobe       = 1'b1;
        spi_wb_cycle        = 1'b1;
      end

      XIP_WRITE_SLAVE_SELECT: begin
        spi_wb_addr         = SPI_SS_ADDR;
        spi_wb_write_data   = 32'd1;
        spi_wb_write_enable = 1'b1;
        spi_wb_strobe       = 1'b1;
        spi_wb_cycle        = 1'b1;
      end

      XIP_WRITE_CONTROL: begin
        spi_wb_addr         = SPI_CTRL_ADDR;
        spi_wb_write_data   = SPI_CONTROL_CONFIG;
        spi_wb_write_enable = 1'b1;
        spi_wb_strobe       = 1'b1;
        spi_wb_cycle        = 1'b1;
      end

      XIP_START_TRANSFER: begin
        spi_wb_addr         = SPI_CTRL_ADDR;
        spi_wb_write_data   = SPI_CONTROL_START;
        spi_wb_write_enable = 1'b1;
        spi_wb_strobe       = 1'b1;
        spi_wb_cycle        = 1'b1;
      end

      XIP_READ_CONTROL: begin
        spi_wb_addr   = SPI_CTRL_ADDR;
        spi_wb_strobe = 1'b1;
        spi_wb_cycle  = 1'b1;
      end

      XIP_READ_DATA: begin
        spi_wb_addr   = SPI_TXRX0_ADDR;
        spi_wb_strobe = 1'b1;
        spi_wb_cycle  = 1'b1;
      end

      XIP_RETURN_RESPONSE: begin
        apb_response_ready     = 1'b1;
        apb_response_read_data = flash_xip_read_data_q;
      end

      default: begin
        apb_response_ready = 1'b0;
      end
    endcase
  end

  spi_top u0_spi_top (
      .wb_clk_i(clock),
      .wb_rst_i(reset),
      .wb_adr_i(spi_wb_addr),
      .wb_dat_i(spi_wb_write_data),
      .wb_dat_o(spi_wb_read_data),
      .wb_sel_i(spi_wb_byte_enable),
      .wb_we_i (spi_wb_write_enable),
      .wb_stb_i(spi_wb_strobe),
      .wb_cyc_i(spi_wb_cycle),
      .wb_ack_o(spi_wb_ack),
      .wb_err_o(spi_wb_error),
      .wb_int_o(spi_irq_out),

      .ss_pad_o  (spi_ss),
      .sclk_pad_o(spi_sck),
      .mosi_pad_o(spi_mosi),
      .miso_pad_i(spi_miso)
  );

`endif  // FAST_FLASH

endmodule
