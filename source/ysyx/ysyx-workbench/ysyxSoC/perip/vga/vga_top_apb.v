module vga_top_apb(
  input         clock,
  input         reset,
  input  [31:0] in_paddr,
  input         in_psel,
  input         in_penable,
  input  [2:0]  in_pprot,
  input         in_pwrite,
  input  [31:0] in_pwdata,
  input  [3:0]  in_pstrb,
  output        in_pready,
  output [31:0] in_prdata,
  output        in_pslverr,

  output [7:0]  vga_r,
  output [7:0]  vga_g,
  output [7:0]  vga_b,
  output        vga_hsync,
  output        vga_vsync,
  output        vga_valid
);

  localparam [31:0] VGA_FRAMEBUFFER_BASE_ADDR = 32'h2100_0000;
  localparam integer VGA_FRAMEBUFFER_BYTE_SIZE = 2 * 1024 * 1024;
  localparam integer VGA_FRAMEBUFFER_PIXEL_COUNT = VGA_FRAMEBUFFER_BYTE_SIZE / 4;

  localparam [9:0] VGA_HORIZONTAL_SYNC_END     = 10'd96;
  localparam [9:0] VGA_HORIZONTAL_ACTIVE_START = 10'd144;
  localparam [9:0] VGA_HORIZONTAL_ACTIVE_END   = 10'd784;
  localparam [9:0] VGA_HORIZONTAL_TOTAL        = 10'd800;

  localparam [9:0] VGA_VERTICAL_SYNC_END       = 10'd2;
  localparam [9:0] VGA_VERTICAL_ACTIVE_START   = 10'd35;
  localparam [9:0] VGA_VERTICAL_ACTIVE_END     = 10'd515;
  localparam [9:0] VGA_VERTICAL_TOTAL          = 10'd525;

  wire        apb_access;
  wire [18:0] apb_framebuffer_pixel_index;
  wire        apb_framebuffer_address_present;

  assign apb_access = in_psel && in_penable;
  // The 2 MiB framebuffer base is 2 MiB aligned, so bits [20:2] are the
  // 32-bit pixel index inside the mapped window.
  assign apb_framebuffer_pixel_index = in_paddr[20:2];
  assign apb_framebuffer_address_present =
      (in_paddr >= VGA_FRAMEBUFFER_BASE_ADDR) &&
      (in_paddr < (VGA_FRAMEBUFFER_BASE_ADDR + VGA_FRAMEBUFFER_BYTE_SIZE));

  assign in_pready  = 1'b1;
  assign in_pslverr = apb_access && !apb_framebuffer_address_present;

  // Each entry stores one pixel in 0x00RRGGBB format. The APB port writes the
  // framebuffer while the VGA scan port reads it independently.
  reg [31:0] framebuffer_pixel_array [0:VGA_FRAMEBUFFER_PIXEL_COUNT-1];

  always @(posedge clock) begin
    if (!reset && apb_access && in_pwrite && apb_framebuffer_address_present) begin
      if (in_pstrb[0]) begin
        framebuffer_pixel_array[apb_framebuffer_pixel_index][7:0]
            <= in_pwdata[7:0];
      end
      if (in_pstrb[1]) begin
        framebuffer_pixel_array[apb_framebuffer_pixel_index][15:8]
            <= in_pwdata[15:8];
      end
      if (in_pstrb[2]) begin
        framebuffer_pixel_array[apb_framebuffer_pixel_index][23:16]
            <= in_pwdata[23:16];
      end
      if (in_pstrb[3]) begin
        framebuffer_pixel_array[apb_framebuffer_pixel_index][31:24]
            <= in_pwdata[31:24];
      end
    end
  end

  assign in_prdata = apb_framebuffer_address_present
                   ? framebuffer_pixel_array[apb_framebuffer_pixel_index]
                   : 32'b0;

  reg [9:0] horizontal_cycle_count_q;
  reg [9:0] vertical_line_count_q;

  always @(posedge clock) begin
    if (reset) begin
      horizontal_cycle_count_q <= 10'd1;
      vertical_line_count_q    <= 10'd1;
    end else if (horizontal_cycle_count_q == VGA_HORIZONTAL_TOTAL) begin
      horizontal_cycle_count_q <= 10'd1;
      if (vertical_line_count_q == VGA_VERTICAL_TOTAL) begin
        vertical_line_count_q <= 10'd1;
      end else begin
        vertical_line_count_q <= vertical_line_count_q + 10'd1;
      end
    end else begin
      horizontal_cycle_count_q <= horizontal_cycle_count_q + 10'd1;
    end
  end

  wire horizontal_active_region;
  wire vertical_active_region;
  wire [9:0] active_pixel_x;
  wire [9:0] active_pixel_y;
  wire [18:0] scan_framebuffer_pixel_index;
  wire [31:0] scan_pixel_data;

  assign horizontal_active_region =
      (horizontal_cycle_count_q > VGA_HORIZONTAL_ACTIVE_START) &&
      (horizontal_cycle_count_q <= VGA_HORIZONTAL_ACTIVE_END);
  assign vertical_active_region =
      (vertical_line_count_q > VGA_VERTICAL_ACTIVE_START) &&
      (vertical_line_count_q <= VGA_VERTICAL_ACTIVE_END);

  assign active_pixel_x = horizontal_active_region
                        ? horizontal_cycle_count_q - 10'd145
                        : 10'd0;
  assign active_pixel_y = vertical_active_region
                        ? vertical_line_count_q - 10'd36
                        : 10'd0;
  assign scan_framebuffer_pixel_index = active_pixel_y * 19'd640 +
                                          {9'b0, active_pixel_x};
  assign scan_pixel_data = framebuffer_pixel_array[scan_framebuffer_pixel_index];

  assign vga_hsync = horizontal_cycle_count_q > VGA_HORIZONTAL_SYNC_END;
  assign vga_vsync = vertical_line_count_q > VGA_VERTICAL_SYNC_END;
  assign vga_valid = horizontal_active_region && vertical_active_region;

  assign vga_r = vga_valid ? scan_pixel_data[23:16] : 8'b0;
  assign vga_g = vga_valid ? scan_pixel_data[15:8]  : 8'b0;
  assign vga_b = vga_valid ? scan_pixel_data[7:0]   : 8'b0;

endmodule
