// 恢复请求组合选择：下标越大优先级越高。此模块不增加恢复流水级。
module riscv32_redirect_mux
  import riscv32_pkg::*;
#(parameter int unsigned SOURCE_COUNT = 2) (
    input  redirect_req_t           redirect_req_i [SOURCE_COUNT],
    input  logic [SOURCE_COUNT-1:0] redirect_req_valid_i,
    output redirect_req_t          redirect_req_o,
    output logic                   redirect_req_valid_o
);
  always_comb begin
    redirect_req_o = '0;
    redirect_req_valid_o = |redirect_req_valid_i;
    for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
      if (redirect_req_valid_i[source])
        redirect_req_o = redirect_req_i[source];
    end
  end
endmodule
