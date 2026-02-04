module key_processor(
    input clk,
    input rstn,
    input [7:0] ps2_data,
    input ps2_ready,
    output reg [7:0] cur_code,
    output reg is_pressing,
    output  shift_flag,
    output  ctrl_flag,
    output reg count_en
);

    localparam IDLE = 1'b0;
    localparam BREAK = 1'b1;

    reg shift_is_pressing;
    reg ctrl_is_pressing;

    assign shift_flag = shift_is_pressing;
    assign ctrl_flag = ctrl_is_pressing;

    reg current_state;
    reg next_state;

    wire is_func_key = (ps2_data == 8'h12 || ps2_data == 8'h59 || ps2_data == 8'h14);

    always @(posedge clk) begin
        if(!rstn)begin
          current_state <= IDLE;
        end    
        else begin
          current_state <= next_state;
        end
    end

    always @( *) begin
        case(current_state)
            IDLE: begin
                if(ps2_ready && ps2_data == 8'hF0)
                    next_state = BREAK;
                else
                    next_state = IDLE;
            end

            BREAK: begin
                if(ps2_ready)
                    next_state = IDLE;
                else
                    next_state = BREAK;
            end

            default : next_state = IDLE;
                
        endcase
    end


    always @(posedge clk) begin
        if(!rstn)begin
          cur_code <= 8'b0;
          is_pressing <= 1'b0;
          count_en <= 1'b0;
        end
        
        else begin
            count_en <= 1'b0;
            if(ps2_ready)begin
                case(current_state)
                    IDLE:begin
                      if(ps2_data != 8'hF0 && !is_func_key)begin
                        cur_code <= ps2_data;
                        if(!is_pressing)begin
                          count_en <= 1'b1;
                        end
                        is_pressing <= 1'b1;
                      end
                    end

                    BREAK:begin
                      if(!is_func_key) is_pressing <= 1'b0;  
                    end
                endcase
            end
        end
    end

    always @(posedge clk) begin
        if(!rstn)begin
          shift_is_pressing <= 1'b0;
          ctrl_is_pressing <= 1'b0;
        end
        else begin
            if(ps2_ready)begin
                case(current_state)
                    IDLE:begin
                        if(ps2_data == 8'h12 || ps2_data == 8'h59)
                            shift_is_pressing <= 1'b1;
                        else if(ps2_data == 8'h14)
                            ctrl_is_pressing <= 1'b1;
                    end
                    BREAK:begin
                        if(ps2_data == 8'h12 || ps2_data == 8'h59)
                            shift_is_pressing <= 1'b0;
                        else if(ps2_data == 8'h14)
                            ctrl_is_pressing <= 1'b0;
                    end
                endcase   
            end
        end
    end

endmodule
