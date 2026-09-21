// 条件分支方向表：PC索引的两位饱和计数器。
// 组合查询直接参与预测选择；训练输入已经过共享解析事件寄存器。
// 同沿查询读取更新前的计数值，没有查询旁路。invalidate不清此表。
module riscv32_bht
  import riscv32_pkg::*;
#(
    parameter int unsigned BHT_ENTRY_COUNT = riscv_config_pkg::BRANCH_HISTORY_ENTRY_COUNT
) (
    input  logic                   clk_i,
    input  logic                   rst_ni,
    input  program_counter_t       lookup_pc_i,
    output logic             [1:0] lookup_counter_o,
    input  program_counter_t       training_pc_i,
    input  logic                   training_valid_i,
    input  logic                   training_taken_i
);
  localparam int unsigned INDEX_WIDTH = $clog2(BHT_ENTRY_COUNT);
  localparam int unsigned INSTRUCTION_OFFSET_WIDTH = $clog2(INSTRUCTION_BYTES);
  typedef logic [INDEX_WIDTH-1:0] branch_history_index_t;

  logic                  [1:0] counter_array_q[BHT_ENTRY_COUNT];
  branch_history_index_t       lookup_index;
  branch_history_index_t       training_index;

  initial begin
    if ((BHT_ENTRY_COUNT < 2) || ((BHT_ENTRY_COUNT & (BHT_ENTRY_COUNT - 1)) != 0)) begin
      $fatal(1, "branch history entry count must be a power of two and at least 2");
    end
  end

  // 1. 查询读口：只取地址索引，不增加查询寄存级。
  assign lookup_index     = lookup_pc_i[INSTRUCTION_OFFSET_WIDTH+:INDEX_WIDTH];
  assign training_index   = training_pc_i[INSTRUCTION_OFFSET_WIDTH+:INDEX_WIDTH];
  assign lookup_counter_o = counter_array_q[lookup_index];

  // 2. 训练运算：先读当前计数器，再做两位饱和加减。
  function automatic logic [1:0] update_counter(input logic [1:0] current_counter,
                                                input logic taken);
    if (taken) begin
      return (current_counter == 2'b11) ? current_counter : current_counter + 2'b01;
    end
    return (current_counter == 2'b00) ? current_counter : current_counter - 2'b01;
  endfunction

  logic [1:0] training_counter_next;
  assign training_counter_next = update_counter(counter_array_q[training_index], training_taken_i);

  // 3. 同步写口：00/01 预测不跳，10/11 预测跳转。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned entry_index = 0; entry_index < BHT_ENTRY_COUNT; entry_index++) begin
        counter_array_q[entry_index] <= 2'b01;
      end
    end else if (training_valid_i) begin
      counter_array_q[training_index] <= training_counter_next;
    end
  end
endmodule
