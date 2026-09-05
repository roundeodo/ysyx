// 组合选择优先级最高的重定向请求。
module riscv_redirect_arbiter
  import riscv_pkg::*;
#(
    parameter int unsigned SOURCE_COUNT = 2
) (
    input redirect_req_t                    redirect_req_i      [SOURCE_COUNT],
    input logic          [SOURCE_COUNT-1:0] redirect_req_valid_i,

    output redirect_req_t selected_redirect_req_o,
    output logic          selected_redirect_req_valid_o
);
  // 下标越大优先级越高。该组合仲裁器仍在 filelist 中，但当前 core 使用
  // riscv_frontend_redirect_register，不实例化本模块。
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

  // 若后续用于乱序恢复，需要按指令年龄选择请求，不能只依靠固定端口优先级。

endmodule
