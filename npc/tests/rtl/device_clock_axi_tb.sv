`timescale 1ns / 1ns
module device_clock_axi_tb #(
    parameter integer CPU_MHZ = 720,
    parameter integer MODE = 1
);
  localparam longint RATIO_SCALED = CPU_MHZ * 1024 / 100;
  wire           device_clock_o;
  integer        LATE_READ = 0;
  logic          clock;
  logic          reset;

  logic          in_arready;
  logic          in_arvalid;
  logic   [ 3:0] in_arid;
  logic   [31:0] in_araddr;
  logic   [ 7:0] in_arlen;
  logic   [ 2:0] in_arsize;
  logic   [ 1:0] in_arburst;
  logic          in_rready;
  logic          in_rvalid;
  logic   [ 3:0] in_rid;
  logic   [31:0] in_rdata;
  logic   [ 1:0] in_rresp;
  logic          in_rlast;

  logic          in_awready;
  logic          in_awvalid;
  logic   [ 3:0] in_awid;
  logic   [31:0] in_awaddr;
  logic   [ 7:0] in_awlen;
  logic   [ 2:0] in_awsize;
  logic   [ 1:0] in_awburst;
  logic          in_wready;
  logic          in_wvalid;
  logic   [31:0] in_wdata;
  logic   [ 3:0] in_wstrb;
  logic          in_wlast;
  logic          in_bready;
  logic          in_bvalid;
  logic   [ 3:0] in_bid;
  logic   [ 1:0] in_bresp;

  logic          out_arready;
  logic          out_arvalid;
  logic   [ 3:0] out_arid;
  logic   [31:0] out_araddr;
  logic   [ 7:0] out_arlen;
  logic   [ 2:0] out_arsize;
  logic   [ 1:0] out_arburst;
  logic          out_rready;
  logic          out_rvalid;
  logic   [ 3:0] out_rid;
  logic   [31:0] out_rdata;
  logic   [ 1:0] out_rresp;
  logic          out_rlast;

  logic          out_awready;
  logic          out_awvalid;
  logic   [ 3:0] out_awid;
  logic   [31:0] out_awaddr;
  logic   [ 7:0] out_awlen;
  logic   [ 2:0] out_awsize;
  logic   [ 1:0] out_awburst;
  logic          out_wready;
  logic          out_wvalid;
  logic   [31:0] out_wdata;
  logic   [ 3:0] out_wstrb;
  logic          out_wlast;
  logic          out_bready;
  logic          out_bvalid;
  logic   [ 3:0] out_bid;
  logic   [ 1:0] out_bresp;

  axi4_delayer #(
      .DEVICE_TIMING_MODE(MODE),
      .CPU_FREQUENCY_HZ(64'd1000000 * CPU_MHZ),
      .PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED(RATIO_SCALED),
      .FREQUENCY_RATIO_SCALE_SHIFT(10),
      .READ_RESPONSE_BUFFER_DEPTH(16),
      .READ_RESPONSE_BUFFER_ADDR_WIDTH(4)
  ) u_axi4_delayer (
      .*
  );



  logic [3:0] ram_wr;
  logic ram_rd, ram_ack;
  logic [7:0] ram_len;
  logic [31:0] ram_addr, ram_data;
  sdram_axi_pmem u_pmem (
      .clk_i(device_clock_o),
      .rst_i(reset),
      .axi_awvalid_i(out_awvalid),
      .axi_awaddr_i(out_awaddr),
      .axi_awid_i(out_awid),
      .axi_awlen_i(out_awlen),
      .axi_awsize_i(out_awsize),
      .axi_awburst_i(out_awburst),
      .axi_awready_o(out_awready),
      .axi_wvalid_i(out_wvalid),
      .axi_wdata_i(out_wdata),
      .axi_wstrb_i(out_wstrb),
      .axi_wlast_i(out_wlast),
      .axi_wready_o(out_wready),
      .axi_bready_i(out_bready),
      .axi_bvalid_o(out_bvalid),
      .axi_bresp_o(out_bresp),
      .axi_bid_o(out_bid),
      .axi_arvalid_i(out_arvalid),
      .axi_araddr_i(out_araddr),
      .axi_arid_i(out_arid),
      .axi_arlen_i(out_arlen),
      .axi_arsize_i(out_arsize),
      .axi_arburst_i(out_arburst),
      .axi_arready_o(out_arready),
      .axi_rready_i(out_rready),
      .axi_rvalid_o(out_rvalid),
      .axi_rdata_o(out_rdata),
      .axi_rresp_o(out_rresp),
      .axi_rid_o(out_rid),
      .axi_rlast_o(out_rlast),
      .ram_accept_i(1'b1),
      .ram_ack_i(ram_ack),
      .ram_error_i(1'b0),
      .ram_read_data_i(32'hcafef00d),
      .ram_wr_o(ram_wr),
      .ram_rd_o(ram_rd),
      .ram_len_o(ram_len),
      .ram_addr_o(ram_addr),
      .ram_write_data_o(ram_data)
  );
  // A one-cycle physical service stub. Arbitration and AXI queues are production RTL.
  always @(posedge device_clock_o) ram_ack <= !reset && ((|ram_wr) || ram_rd);
  initial begin
    clock = 0;
    forever #1 clock = ~clock;
  end
  integer cycle = 0, write_words = 0, cpu_words = 0, r_start = -1;
  integer r_down = -1, r_up = -1, ar_down = -1, w_last = -1, b_up = -1;
  always @(posedge clock) begin
    if (!reset) begin
      if (in_arvalid && r_start < 0) r_start = cycle;
      if (device_clock_o && out_arvalid && out_arready) ar_down = cycle;
      if (device_clock_o && out_wvalid && out_wready) begin
        if (out_wdata !== 32'h12340000 + write_words || out_wlast !== (write_words == 3))
          $fatal(1, "write payload/order error");
        write_words++;
        if (out_wlast) w_last = cycle;
      end
      if (in_wvalid && in_wready) cpu_words++;
      if (device_clock_o && out_rvalid && out_rready) r_down = cycle;
      if (in_rvalid && in_rready) begin
        if (in_rdata !== 32'hcafef00d || in_rresp != 0 || !in_rlast || in_rid != 6)
          $fatal(1, "read response error");
        r_up = cycle;
      end
      if (in_bvalid && in_bready) begin
        if (cpu_words != 4 || write_words != 4 || in_bresp != 0 || in_bid != 5)
          $fatal(1, "write response error");
        b_up = cycle;
      end
      cycle++;
    end
  end
  initial begin
    void'($value$plusargs("LATE_READ=%d", LATE_READ));
    reset = 1;
    ram_ack = 0;
    in_arvalid = 0;
    in_arid = 6;
    in_araddr = 32'ha0000100;
    in_arlen = 0;
    in_arsize = 2;
    in_arburst = 1;
    in_rready = 1;
    in_awvalid = 0;
    in_awid = 5;
    in_awaddr = 32'ha0000000;
    in_awlen = 3;
    in_awsize = 2;
    in_awburst = 1;
    in_wvalid = 0;
    in_wdata = 0;
    in_wstrb = 15;
    in_wlast = 0;
    in_bready = 1;
    repeat (3) @(negedge clock);
    reset = 0;
    in_awvalid = 1;
    in_wvalid = 1;
    in_wdata = 32'h12340000;
    fork
      begin
        do @(posedge clock); while (!in_awready);
        @(negedge clock);
        in_awvalid = 0;
      end
      begin
        for (integer i = 0; i < 4; i++) begin
          in_wdata = 32'h12340000 + i;
          in_wlast = (i == 3);
          do @(posedge clock); while (!in_wready);
          @(negedge clock);
        end
        in_wvalid = 0;
        in_wlast  = 0;
      end
      begin
        if (LATE_READ) wait (b_up >= 0);
        else wait (write_words > 0);
        @(negedge clock);
        in_arvalid = 1;
        do @(posedge clock); while (!in_arready);
        @(negedge clock);
        in_arvalid = 0;
      end
    join
    wait (r_up >= 0 && b_up >= 0);
    @(negedge clock);
    $display(
        "{\"ratio_scaled\":%0d,\"late_read\":%0d,\"ar_start\":%0d,\"ar_down\":%0d,\"wlast_down\":%0d,\"b_up\":%0d,\"r_down\":%0d,\"r_up\":%0d}",
        RATIO_SCALED, LATE_READ, r_start, ar_down, w_last, b_up, r_down, r_up);
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "probe timeout");
  end
endmodule
