// Select and register one resolved control-flow recovery event before frontend control.
//
// Each source payload is captured directly, while only the selected source index passes
// through priority logic. This prevents the wide redirect payload from crossing an arbiter
// before its register. Higher array indices have higher architectural priority.
module riscv32_frontend_redirect_register
  import riscv32_pkg::*;
#(
    parameter int unsigned SOURCE_COUNT = 2
)
(
    input logic clk_i,
    input logic rst_ni,

    input redirect_req_t                    redirect_req_i      [SOURCE_COUNT],
    input logic          [SOURCE_COUNT-1:0] redirect_req_valid_i,

    output redirect_req_t registered_redirect_req_o,
    output logic          registered_redirect_req_valid_o
);

  localparam int unsigned SOURCE_INDEX_WIDTH =
      SOURCE_COUNT <= 1 ? 1 : $clog2(SOURCE_COUNT);

  typedef logic [SOURCE_INDEX_WIDTH-1:0] source_index_t;

  redirect_req_t registered_redirect_req_q[SOURCE_COUNT];
  source_index_t selected_source_index_q;
  logic          registered_redirect_req_valid_q;

  assign registered_redirect_req_o = registered_redirect_req_valid_q ?
      registered_redirect_req_q[selected_source_index_q] : '0;
  assign registered_redirect_req_valid_o = registered_redirect_req_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
        registered_redirect_req_q[source] <= '0;
      end
      selected_source_index_q           <= '0;
      registered_redirect_req_valid_q <= 1'b0;
    end else begin
      registered_redirect_req_valid_q <= |redirect_req_valid_i;

      // Ascending iteration plus nonblocking assignment gives the highest valid index
      // priority without placing the payload itself behind the priority multiplexer.
      for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
        if (redirect_req_valid_i[source]) begin
          registered_redirect_req_q[source] <= redirect_req_i[source];
          selected_source_index_q <= source_index_t'(source);
        end
      end
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (|redirect_req_valid_i) |=> registered_redirect_req_valid_o)
  else $error("frontend redirect register lost a recovery event");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    !(|redirect_req_valid_i) |=> !registered_redirect_req_valid_o)
  else $error("frontend redirect register created a recovery event");
`endif

endmodule
