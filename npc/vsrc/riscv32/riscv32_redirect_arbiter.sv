module riscv32_redirect_arbiter
  import riscv32_pkg::*;
#(
    parameter int unsigned SOURCE_COUNT = 2
) (
    input redirect_req_t                    redirect_i      [SOURCE_COUNT],
    input logic          [SOURCE_COUNT-1:0] redirect_valid_i,

    output redirect_req_t redirect_o,
    output logic          redirect_valid_o
);
  // Higher array indices have higher priority. P0 connects execute recovery at
  // index 0 and committed trap/mret at index 1, so architectural redirects win.
  always_comb begin
    redirect_o       = '0;
    redirect_valid_o = 1'b0;

    for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
      if (redirect_valid_i[source]) begin
        redirect_o       = redirect_i[source];
        redirect_valid_o = 1'b1;
      end
    end
  end

  // NOTE(P6): speculative sources must then carry valid ROB ages; among them,
  // choose the oldest recovery request while preserving commit-level priority.

endmodule
