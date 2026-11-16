// 只使用未门控时钟。异步进入复位，两级上升沿同步后在下降沿统一释放。
module riscv32_reset_controller (
    input  logic clk_i,
    input  logic rst_ni,
    output logic rst_no
);
  (* async_reg = "true", keep = 1 *) logic [1:0] reset_release_sync_q;
  logic reset_release_q;

  assign rst_no = reset_release_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reset_release_sync_q <= 2'b00;
    end else begin
      reset_release_sync_q <= {reset_release_sync_q[0], 1'b1};
    end
  end

  // 下游是上升沿触发器；释放放在下降沿，为 recovery/removal 留出半周期。
  always_ff @(negedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reset_release_q <= 1'b0;
    end else begin
      reset_release_q <= reset_release_sync_q[1];
    end
  end
endmodule : riscv32_reset_controller
