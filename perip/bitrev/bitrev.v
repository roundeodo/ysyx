module bitrev (
    input  wire sck,
    input  wire ss,
    input  wire mosi,
    output reg  miso
);
  // sample number of bit
  reg [4:0] bit_count;

  // serial receiver
  reg [7:0] rx_shift;

  // saved result
  reg [7:0] tx_data;

  function automatic [7:0] reverse8(input [7:0] value);
    integer i;
    begin
      for (i = 0; i < 8; i = i + 1) begin
        reverse8[i] = value[7-i];
      end
    end
  endfunction

  always @(posedge sck or posedge ss) begin
    if (ss) begin
      bit_count <= 5'd0;
      rx_shift  <= 8'd0;
      tx_data   <= 8'd0;
    end else begin
      if (bit_count < 5'd8) begin
        rx_shift <= {rx_shift[6:0], mosi};

        if (bit_count == 5'd7) begin
          tx_data <= reverse8({rx_shift[6:0], mosi});
        end
      end

      if (bit_count < 5'd16) begin
        bit_count <= bit_count + 5'd1;
      end
    end
  end

  always @(negedge sck or negedge ss) begin
    if (ss) begin
      miso <= 1'b1;
    end else begin
      if (bit_count >= 5'd8 && (bit_count <= 5'd16)) begin
        miso <= tx_data[15-bit_count];
      end else miso <= 1'b1;
    end
  end
endmodule
