module gpio_top_apb (
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

    output [15:0] gpio_out,
    input  [15:0] gpio_in,
    output [ 7:0] gpio_seg_0,
    output [ 7:0] gpio_seg_1,
    output [ 7:0] gpio_seg_2,
    output [ 7:0] gpio_seg_3,
    output [ 7:0] gpio_seg_4,
    output [ 7:0] gpio_seg_5,
    output [ 7:0] gpio_seg_6,
    output [ 7:0] gpio_seg_7
);

  localparam [3:0] GPIO_LED_OFFSET = 4'h0;
  localparam [3:0] GPIO_SWITCH_OFFSET = 4'h4;
  localparam [3:0] GPIO_SEGMENT_OFFSET = 4'h8;

  wire apb_access;
  wire [3:0] register_offset;
  wire register_offset_supported;

  assign apb_access = in_psel && in_penable;
  assign register_offset = in_paddr[3:0];

  assign register_offset_supported = (register_offset == GPIO_LED_OFFSET) || (register_offset == GPIO_SWITCH_OFFSET) || (register_offset == GPIO_SEGMENT_OFFSET);

  assign in_pready = 1'b1;
  assign in_pslverr = apb_access && !register_offset_supported;

  reg [15:0] led_output_q;

  always @(posedge clock) begin
    if (reset) begin
      led_output_q <= 16'b0;
    end else if (apb_access && in_pwrite && register_offset == GPIO_LED_OFFSET) begin
      if (in_pstrb[0]) begin
        led_output_q[7:0] <= in_pwdata;
      end
      if (in_pstrb[1]) begin
        led_output_q[15:8] <= in_pwdata[15:8];
      end
    end
  end

  assign gpio_out = led_output_q;

  reg [15:0] gpio_input_metastability_q;
  reg [15:0] gpio_input_synchronized_q;

  always @(posedge clock) begin
    if (reset) begin
      gpio_input_metastability_q <= 16'b0;
      gpio_input_synchronized_q  <= 16'b0;
    end else begin
      gpio_input_metastability_q <= gpio_in;
      gpio_input_synchronized_q  <= gpio_input_metastability_q;
    end
  end

  reg [31:0] seven_segment_digit_values_q;

  always @(posedge clock) begin
    if (reset) begin
      seven_segment_digit_values_q <= 32'b0;
    end else if (apb_access && in_pwrite && register_offset == GPIO_SEGMENT_OFFSET) begin
      if (in_pstrb[0]) begin
        seven_segment_digit_values_q[7:0] <= in_pwdata[7:0];
      end
      if (in_pstrb[1]) begin
        seven_segment_digit_values_q[15:8] <= in_pwdata[15:8];
      end
      if (in_pstrb[2]) begin
        seven_segment_digit_values_q[23:16] <= in_pwdata[23:16];
      end
      if (in_pstrb[3]) begin
        seven_segment_digit_values_q[31:24] <= in_pwdata[31:24];
      end
    end
  end

  function [7:0] decode_hex_digit_to_segments;
    input [3:0] digit;
    begin
      case (digit)
        4'h0:    decode_hex_digit_to_segments = 8'b00000011;
        4'h1:    decode_hex_digit_to_segments = 8'b10011111;
        4'h2:    decode_hex_digit_to_segments = 8'b00100101;
        4'h3:    decode_hex_digit_to_segments = 8'b00001101;
        4'h4:    decode_hex_digit_to_segments = 8'b10011001;
        4'h5:    decode_hex_digit_to_segments = 8'b01001001;
        4'h6:    decode_hex_digit_to_segments = 8'b01000001;
        4'h7:    decode_hex_digit_to_segments = 8'b00011111;
        4'h8:    decode_hex_digit_to_segments = 8'b00000001;
        4'h9:    decode_hex_digit_to_segments = 8'b00001001;
        4'ha:    decode_hex_digit_to_segments = 8'b00010001;
        4'hb:    decode_hex_digit_to_segments = 8'b11000001;
        4'hc:    decode_hex_digit_to_segments = 8'b01100011;
        4'hd:    decode_hex_digit_to_segments = 8'b10000101;
        4'he:    decode_hex_digit_to_segments = 8'b01100001;
        4'hf:    decode_hex_digit_to_segments = 8'b01110001;
        default: decode_hex_digit_to_segments = 8'b11111111;
      endcase
    end
  endfunction

  assign gpio_seg_0 = decode_hex_digit_to_segments(seven_segment_digit_values_q[3:0]);
  assign gpio_seg_1 = decode_hex_digit_to_segments(seven_segment_digit_values_q[7:4]);
  assign gpio_seg_2 = decode_hex_digit_to_segments(seven_segment_digit_values_q[11:8]);
  assign gpio_seg_3 = decode_hex_digit_to_segments(seven_segment_digit_values_q[15:12]);
  assign gpio_seg_4 = decode_hex_digit_to_segments(seven_segment_digit_values_q[19:16]);
  assign gpio_seg_5 = decode_hex_digit_to_segments(seven_segment_digit_values_q[23:20]);
  assign gpio_seg_6 = decode_hex_digit_to_segments(seven_segment_digit_values_q[27:24]);
  assign gpio_seg_7 = decode_hex_digit_to_segments(seven_segment_digit_values_q[31:28]);

  reg [31:0] apb_read_data;

  always @(*) begin
    case (register_offset)
      GPIO_LED_OFFSET: begin
        apb_read_data = {16'b0, led_output_q};
      end

      GPIO_SWITCH_OFFSET: begin
        apb_read_data = {16'b0, gpio_input_synchronized_q};
      end

      GPIO_SEGMENT_OFFSET: begin
        apb_read_data = seven_segment_digit_values_q;
      end

      default: begin
        apb_read_data = 32'b0;
      end
    endcase
  end

  assign in_prdata = apb_read_data;

endmodule
