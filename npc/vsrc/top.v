module top(
    input clk,
    input rstn,
    input ps2_clk,
    input ps2_data,
    output [6:0] seg0,seg1,seg2,seg3,seg4,seg5,
    output [1:0] leds,
    output overflow_f
);

    wire [7:0] raw_code;
    wire [7:0] processed_code;
    wire [7:0] ascii_code;
    wire [7:0] total_count;
    wire ready, is_pressing,count_en,shift_f,ctrl_f;

    ps2_keyboard ps2_keyboard_inst(
        .clk(clk),
        .clrn(rstn),
        .ps2_clk(ps2_clk),
        .ps2_data(ps2_data),
        .data(raw_code),
        .ready(ready),
        .nextdata_n(1'b0),
        .overflow(overflow_f)
    );

    key_processor key_processor_inst(
        .clk(clk),
        .rstn(rstn),
        .ps2_data(raw_code),
        .ps2_ready(ready),
        .cur_code(processed_code),
        .is_pressing(is_pressing),
        .shift_flag(shift_f),
        .ctrl_flag(ctrl_f),
        .count_en(count_en)
    );

    scan2ascii scan2ascii_inst(
        .scan_code(processed_code),
        .shift_en(shift_f),
        .ascii_code(ascii_code)     
    );

    press_counter press_counter_inst(
        .clk(clk),
        .rstn(rstn),
        .en(count_en),
        .count(total_count)
    );

    wire [7:0] d_code = is_pressing? processed_code : 8'h00;
    wire [7:0] d_ascii = is_pressing? ascii_code : 8'h00;

    bcd7seg digit_tube0(
        .seg_in(d_code[3:0]),
        .seg_out(seg0)
    );

    bcd7seg digit_tube1(
        .seg_in(d_code[7:4]),
        .seg_out(seg1)
    );

    bcd7seg digit_tube2(
        .seg_in(d_ascii[3:0]),
        .seg_out(seg2)
    );

    bcd7seg digit_tube3(
        .seg_in(d_ascii[7:4]),
        .seg_out(seg3)
    );

    bcd7seg digit_tube4(
        .seg_in(total_count[3:0]),
        .seg_out(seg4)
    );

    bcd7seg digit_tube5(
        .seg_in(total_count[7:4]),
        .seg_out(seg5)
    );
assign leds = {ctrl_f,shift_f};
endmodule
