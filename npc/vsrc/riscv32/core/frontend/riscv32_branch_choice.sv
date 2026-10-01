// 条件分支同信息时机对照：纯动态、BTFNT、弱动态回退BTFNT；不增加状态或寄存级。
module riscv32_branch_choice #(
    parameter int unsigned POLICY = riscv_config_pkg::BRANCH_STATIC_POLICY
) (
    input  logic       backward_i,
    input  logic       metadata_valid_i,
    input  logic [1:0] dynamic_counter_i,
    output logic       taken_o
);
  logic dynamic_weak;

  assign dynamic_weak = dynamic_counter_i[1] != dynamic_counter_i[0];

  always_comb begin
    taken_o = dynamic_counter_i[1];
    if (metadata_valid_i) begin
      case (POLICY)
        1:       taken_o = backward_i;
        2:       if (dynamic_weak) taken_o = backward_i;
        default: ;
      endcase
    end
  end

  initial begin
    if (POLICY > 2) $fatal(1, "invalid static/dynamic selection policy");
  end
endmodule
