// Register the response-predecode correction before it re-enters IFU control.
//
// A cold JAL/branch/return may be absent from the request-side predictor. The
// response predecoder can recover it, but feeding that result directly back to
// the next I-cache address creates a data-array -> predecode -> IFU -> data-array
// combinational path. This narrow stage adds one cycle only to such corrections;
// predictor hits continue to request their target without this stage.
module riscv32_fetch_correction_stage
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input redirect_req_t fetch_correction_req_i,
    input logic          fetch_correction_req_valid_i,

    // An older EX/commit recovery invalidates a younger response correction.
    input logic flush_i,

    output redirect_req_t registered_fetch_correction_req_o,
    output logic          registered_fetch_correction_req_valid_o
);

  redirect_req_t registered_fetch_correction_req_q;
  logic          registered_fetch_correction_req_valid_q;

  assign registered_fetch_correction_req_o       = registered_fetch_correction_req_q;
  assign registered_fetch_correction_req_valid_o = registered_fetch_correction_req_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      registered_fetch_correction_req_q       <= '0;
      registered_fetch_correction_req_valid_q <= 1'b0;
    end else if (flush_i) begin
      registered_fetch_correction_req_valid_q <= 1'b0;
    end else begin
      registered_fetch_correction_req_valid_q <= fetch_correction_req_valid_i;
      if (fetch_correction_req_valid_i) begin
        registered_fetch_correction_req_q <= fetch_correction_req_i;
      end
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    registered_fetch_correction_req_valid_q |-> !fetch_correction_req_valid_i)
  else $error("fetch correction stage received a new correction while draining the prior event");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !registered_fetch_correction_req_valid_o)
  else $error("fetch correction stage retained a correction after an older recovery");
`endif

endmodule
