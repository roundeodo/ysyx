// I-cache指令数据存储阵列，按way、line内word和set组织。
//
// 本模块只负责同步读取目标word和接收refill写入，不判断tag，也不决定victim way。
// v1把一条32B cache line拆成8个32位word bank，使hit路径只读出当前取指所需word。
// 未来扩大fetch width或接入多端口SRAM时，应先修改bank组织和端口，而不是把总线
// 或miss控制塞入数据阵列。
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
    // I-cache word宽度由前端fetch配置决定，不随GPR的XLEN自动变化。
    output icache_fetch_data_t read_word_data_array_o[WAY_COUNT],

    input logic               refill_write_valid_i,
    input icache_set_index_t  refill_write_set_index_i,
    input icache_way_index_t  refill_write_way_index_i,
    input icache_word_index_t refill_write_word_index_i,
    input icache_fetch_data_t refill_write_word_data_i
);

  // 端口、读出寄存器和存储阵列使用同一取指数据类型，禁止隐式截断或扩展。
  // 第一版每个bank宽32位，一个cache line由8个word bank组成。
  // 按word分bank可让一次lookup只读出每个way的目标32位，而不是把整条256位line拉到
  // compare/select路径。未来FETCH_WIDTH增加时再评估一次读多个word或扩大bank宽度。
  // 数组的每个[way][word]组合表示一个独立bank，set是该bank内部的读写地址。
  // 因此同一次lookup会并行读取所有way中相同word bank、相同set位置的数据。
  icache_fetch_data_t data_array_q          [WAY_COUNT] [WORDS_PER_LINE] [SET_COUNT];
  icache_fetch_data_t read_word_data_array_q[WAY_COUNT];

  // read_enable_i为1的上升沿，读取所有way中由set和word共同索引的word。读地址必须
  // 与tag array使用同一个set，并由cache pipeline的S0寄存器共同驱动。
  always_ff @(posedge clk_i) begin
    if (read_enable_i) begin
      for (int unsigned way_index = 0; way_index < WAY_COUNT; way_index++) begin
        read_word_data_array_q[way_index] <=
            data_array_q[way_index][read_word_index_i][read_set_index_i];
      end
    end
  end

  // 连续赋值不会增加hit latency。read_enable_i为0时，读出寄存器保持上次内容；I-cache
  // 顶层必须使用对应流水级的present位判断输出是否属于当前lookup。
  for (genvar way_index = 0; way_index < WAY_COUNT; way_index++) begin : gen_read_data_output
    assign read_word_data_array_o[way_index] = read_word_data_array_q[way_index];
  end

  // refill_write_valid_i为1时，只更新指定way/set/word。I-cache只读，所以没有dirty
  // bit和store byte mask。数据阵列无需复位；line是否可被命中完全由tag array中的
  // present位决定。
  //
  // 第一版blocking cache可禁止lookup与refill写同一set。未来early restart和hit-under-
  // miss需要定义冲突策略，并优先考虑refill data bypass而不是依赖SRAM read-during-write
  // 的工艺相关行为。
  //
  // 这里不是循环写完整条line。每次refill response握手只携带一个word及其word index，
  // miss unit连续驱动本写口，逐word填满cache line。
  // 只有该line的所有word均成功写入后，miss unit才允许tag array把对应present写成1。
  // 本模块不能自行修改metadata，否则data和metadata提交时序会出现两个控制来源。
  always_ff @(posedge clk_i) begin
    if (refill_write_valid_i) begin
      data_array_q[refill_write_way_index_i]
                  [refill_write_word_index_i]
                  [refill_write_set_index_i] <= refill_write_word_data_i;
    end
  end

  // v1由I-cache顶层保证lookup与refill不会在同一拍访问同一个set。data array不在
  // 本地重复实现冲突检测；未来若支持hit-under-miss，应在顶层定义refill bypass。

  // directed test至少覆盖以下顺序：
  // 1. 向way0/set3/word2写32'h1111_2222；
  // 2. 向way1/set3/word2写32'h3333_4444；
  // 3. 对set3/word2发起一次同步读，在下一个上升沿后检查两个way输出分别对应上述值；
  // 4. 再写set4/word2和set3/word5，确认set索引和word索引没有互换；
  // 5. read_enable_i=0保持一拍，确认输出保持不变。

endmodule
