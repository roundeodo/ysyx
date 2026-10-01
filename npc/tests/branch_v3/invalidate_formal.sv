// 小几何有界检查：invalidate优先于同拍查询/训练；不假设训练索引恰好正确。
module invalidate_formal (
    input logic clk, rst_n, invalidate, training_valid, taken,
    input logic [31:0] pc,
    input logic [191:0] training_context
);
  logic [8191:0] state_bits;
  riscv32_tage_scl #(
      .BASE_ENTRIES(16),.TAGGED_ENTRIES(8),.TABLE_COUNT(2),.TAG_BITS(6),
      .HISTORY_BITS_0(3),.HISTORY_BITS_1(7),.SC_ENABLE(1),.LOOP_ENABLE(1)
  ) dut (
      .clk_i(clk),.rst_ni(rst_n),.lookup_pc_i(pc),.taken_o(),.context_o(),
      .training_valid_i(training_valid),.training_taken_i(taken),
      .training_context_i(training_context),.state_o(state_bits),
      .lookup_handshake_i(1'b1),.lookup_conditional_i(1'b1),.lookup_taken_i(taken),
      .flush_i(1'b0),.invalidate_i(invalidate));
  logic past_present = 0;
  logic previous_invalidate;
  logic [8191:0] previous_state;
  always @(posedge clk) begin
    past_present <= 1;
    previous_invalidate <= rst_n && invalidate;
    previous_state <= state_bits;
    if (!past_present) assume(!rst_n);
    else assume(rst_n);
    if (past_present && previous_invalidate) begin
      assert(state_bits[31:0] == previous_state[31:0]); // base保持
      assert(state_bits[223:32] == 0);                  // 2*8*12 tagged失效
      assert(state_bits[230:224] == 0);                 // GHR
      assert(state_bits[246:231] == previous_state[246:231] + 16'd1);
      assert(state_bits[375:247] == previous_state[375:247]); // selector/SC保持
      assert(state_bits[611:376] == 0);                 // loop与增量fold清零
    end
  end
endmodule
