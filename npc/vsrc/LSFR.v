module LSFR(
    input clk,
    input rstn,
    output [7:0] LSFR_out
);

    reg [7:0] LSFR_DATA;

    wire feedback = LSFR_DATA[4] ^ LSFR_DATA[3] ^ LSFR_DATA[2] ^ LSFR_DATA[0];

    always @(posedge clk or negedge rstn) begin
        if(!rstn)begin
          LSFR_DATA <= 8'h1;
        end
        else begin
            LSFR_DATA <= {feedback,LSFR_DATA[7:1]};
        end
    end

    assign LSFR_out = LSFR_DATA;
endmodule
