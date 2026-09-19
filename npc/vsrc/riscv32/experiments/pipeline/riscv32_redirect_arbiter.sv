module riscv32_redirect_arbiter
  import riscv32_pkg::*;
#(
    parameter int unsigned SOURCE_COUNT = 2
) (
    input  redirect_req_t           redirect_req_i      [SOURCE_COUNT],
    input  logic [SOURCE_COUNT-1:0] redirect_req_valid_i,

    output redirect_req_t selected_redirect_req_o,
    output logic          selected_redirect_req_valid_o
);
  // 通用组合仲裁器：数组索引越高，优先级越高。当前 core 使用带寄存器的恢复模块。
  always_comb begin
    selected_redirect_req_o       = '0;
    selected_redirect_req_valid_o = 1'b0;

    for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
      if (redirect_req_valid_i[source]) begin
        selected_redirect_req_o       = redirect_req_i[source];
        selected_redirect_req_valid_o = 1'b1;
      end
    end
  end

endmodule
