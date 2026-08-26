// Register one resolved control-flow recovery event before it enters frontend control.
//
// The pipeline still flushes younger instructions in the cycle that discovers the event.
// Only the low-bandwidth frontend request is delayed by one cycle, cutting the long
// commit/execute -> redirect arbitration -> IFU -> I-cache array timing path.
module riscv32_frontend_redirect_register
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input redirect_req_t redirect_req_i,
    input logic          redirect_req_valid_i,
    // An older recovery event cancels a younger event before it reaches the frontend.
    input logic          cancel_i,

    output redirect_req_t registered_redirect_req_o,
    output logic          registered_redirect_req_valid_o
);

  redirect_req_t registered_redirect_req_q;
  logic          registered_redirect_req_valid_q;

  assign registered_redirect_req_o       = registered_redirect_req_q;
  assign registered_redirect_req_valid_o = registered_redirect_req_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      registered_redirect_req_q       <= '0;
      registered_redirect_req_valid_q <= 1'b0;
    end else if (cancel_i) begin
      registered_redirect_req_valid_q <= 1'b0;
    end else begin
      registered_redirect_req_valid_q <= redirect_req_valid_i;
      if (redirect_req_valid_i) begin
        registered_redirect_req_q <= redirect_req_i;
      end
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    cancel_i |=> !registered_redirect_req_valid_o)
  else $error("cancelled redirect reached frontend");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (redirect_req_valid_i && !cancel_i) |=>
      (registered_redirect_req_valid_o &&
       registered_redirect_req_o == $past(redirect_req_i)))
  else $error("frontend redirect register lost or changed a recovery event");
`endif

endmodule
