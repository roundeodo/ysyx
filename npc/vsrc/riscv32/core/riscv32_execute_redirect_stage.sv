// Register the EX recovery event before it enters frontend control. This narrow
// stage cuts the branch-result -> hazard/redirect -> IFU feedback path without
// adding a register to every execute result.
module riscv32_execute_redirect_stage
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input redirect_req_t execute_redirect_req_i,
    input logic          execute_redirect_req_valid_i,
    input logic          flush_i,

    output redirect_req_t registered_redirect_req_o,
    output logic          registered_redirect_req_valid_o
);
  redirect_req_t registered_redirect_req_q;
  logic          registered_redirect_req_valid_q;

  assign registered_redirect_req_o       = registered_redirect_req_q;
  assign registered_redirect_req_valid_o = registered_redirect_req_valid_q;

  // A redirect is a one-cycle event. A committed redirect flushes a younger EX
  // recovery before it can become visible in the following cycle.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      registered_redirect_req_q       <= '0;
      registered_redirect_req_valid_q <= 1'b0;
    end else if (flush_i) begin
      registered_redirect_req_valid_q <= 1'b0;
    end else begin
      registered_redirect_req_valid_q <= execute_redirect_req_valid_i;
      if (execute_redirect_req_valid_i) begin
        registered_redirect_req_q <= execute_redirect_req_i;
      end
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    registered_redirect_req_valid_q |-> !execute_redirect_req_valid_i)
  else $error("execute redirect stage received a new recovery while draining the prior event");
`endif

endmodule
