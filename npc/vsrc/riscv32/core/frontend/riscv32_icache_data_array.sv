// I-cache instruction data storage, organized by way, word, and set.
module riscv32_icache_data_array
  import riscv32_pkg::*;
#(
    parameter int unsigned SET_COUNT      = ICACHE_SET_COUNT,
    parameter int unsigned WAY_COUNT      = ICACHE_WAY_COUNT,
    parameter int unsigned WORDS_PER_LINE = ICACHE_WORDS_PER_LINE
) (
    input logic clk_i,

    input  logic               read_enable_i,
    input  icache_set_index_t  read_set_index_i,
    input  icache_word_index_t read_word_index_i,
    output logic [XLEN-1:0]    read_word_data_array_o[WAY_COUNT],

    input logic                refill_write_valid_i,
    input icache_set_index_t   refill_write_set_index_i,
    input icache_way_index_t   refill_write_way_index_i,
    input icache_word_index_t  refill_write_word_index_i,
    input logic [XLEN-1:0]     refill_write_word_data_i
);

  // TODO(ICACHE-DATA-1): 在本TODO正下方声明data array和同步读出寄存器。
  // 第一版每个bank宽32位，一个cache line由8个word bank组成：
  //
  //   logic [XLEN-1:0] data_array_q [WAY_COUNT][WORDS_PER_LINE][SET_COUNT];
  //   logic [XLEN-1:0] read_word_data_array_q [WAY_COUNT];
  //
  // 按word分bank可让一次lookup只读出每个way的目标32位，而不是把整条256位line拉到
  // compare/select路径。未来FETCH_WIDTH增加时再评估一次读多个word或扩大bank宽度。

  // TODO(ICACHE-DATA-2): 在本TODO正下方实现同步读取。
  // read_enable_i为1的上升沿，读取所有way中由set和word共同索引的word。读地址必须
  // 与tag array使用同一个set，并由cache pipeline的S0寄存器共同驱动。
  //
  //   always_ff @(posedge clk_i) begin
  //     if (read_enable_i) begin
  //       for (int unsigned way_index = 0; way_index < WAY_COUNT; way_index++) begin
  //         read_word_data_array_q[way_index] <=
  //             data_array_q[way_index][read_word_index_i][read_set_index_i];
  //       end
  //     end
  //   end

  // TODO(ICACHE-DATA-3): 在本TODO正下方实现每周期一个word的refill写入。
  // refill_write_valid_i为1时，只更新指定way/set/word。I-cache只读，所以没有dirty
  // bit和store byte mask。数据阵列无需复位；line是否可被命中完全由tag array中的
  // present位决定。
  //
  // 第一版blocking cache可禁止lookup与refill写同一set。未来early restart和hit-under-
  // miss需要定义冲突策略，并优先考虑refill data bypass而不是依赖SRAM read-during-write
  // 的工艺相关行为。

  // TODO(ICACHE-DATA-4): 在本TODO正下方增加索引范围、未知数据和冲突断言。
  // 同时写一个小型directed test：向两个way的相同set/word写不同数据，再逐way检查
  // 同步读结果，确认way、word、set三个维度没有互换。

endmodule
