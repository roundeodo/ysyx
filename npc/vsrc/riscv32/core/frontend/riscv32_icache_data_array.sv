// I-cache指令数据存储阵列，按way、line内word和set组织。
//
// 本模块只负责同步读取目标word和接收refill写入，不判断tag，也不决定哪个line被覆盖。
// cache line按ICACHE_FETCH_BYTES拆成word bank，使hit路径只读出当前取指所需word。
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
    input logic rst_ni,

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
  // 每个bank宽度等于一次fetch交付宽度，bank数由line大小自动派生。
  // 按word分bank可让一次lookup只读出每个way的目标word，而不是把整条line拉到
  // compare/select路径。未来FETCH_WIDTH增加时再评估一次读多个word或扩大bank宽度。
  // 数组的每个[way][word]组合表示一个独立bank，set是该bank内部的读写地址。
  // 因此同一次lookup会并行读取所有way中相同word bank、相同set位置的数据。
  icache_fetch_data_t data_array_q          [WAY_COUNT] [WORDS_PER_LINE] [SET_COUNT];
  icache_fetch_data_t read_word_data_array_q[WAY_COUNT];

  // refill写请求先在上升沿进入staging寄存器，随后在低电平阶段写入数据阵列。
  // staging切断miss-unit组合输出到透明阵列的路径，也保证write payload在整个低电平
  // 写入窗口保持不变。payload在enable=0时没有语义，因此只复位enable。
  icache_set_index_t  staged_refill_write_set_index_q;
  icache_way_index_t  staged_refill_write_way_index_q;
  icache_word_index_t staged_refill_write_word_index_q;
  icache_fetch_data_t staged_refill_write_word_data_q;
  logic               staged_refill_write_enable_q;

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
  // present位决定。这里使用显式staging加低电平透明锁存阵列，降低小容量数据阵列由
  // 标准单元实现时的面积；未来换成SRAM宏时，只需在本模块内部替换存储体和端口时序。
  //
  // 顶层在refill期间只允许读取当前line中更早周期已经写入的word，其他lookup等待
  // 整条line安装完成。该约束保留early restart，同时避免依赖SRAM同地址读写语义。
  //
  // 这里不是循环写完整条line。每次refill response握手只携带一个word及其word index，
  // miss unit连续驱动本写口，逐word填满cache line。
  // 只有该line的所有word均成功写入后，miss unit才允许tag array把对应present写成1。
  // 本模块不能自行修改metadata，否则data和metadata提交时序会出现两个控制来源。
  always_ff @(posedge clk_i) begin
    staged_refill_write_set_index_q  <= refill_write_set_index_i;
    staged_refill_write_way_index_q  <= refill_write_way_index_i;
    staged_refill_write_word_index_q <= refill_write_word_index_i;
    staged_refill_write_word_data_q  <= refill_write_word_data_i;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      staged_refill_write_enable_q <= 1'b0;
    end else begin
      staged_refill_write_enable_q <= refill_write_valid_i;
    end
  end

  always_latch begin
    if (!clk_i && staged_refill_write_enable_q) begin
      data_array_q[staged_refill_write_way_index_q]
                  [staged_refill_write_word_index_q]
                  [staged_refill_write_set_index_q] = staged_refill_write_word_data_q;
    end
  end

  // I-cache顶层负责同set冲突策略，data array不在本地重复比较地址。若未来允许同set
  // hit-under-miss，需要增加明确的refill bypass或双端口SRAM语义。

  // directed test至少覆盖以下顺序：
  // 1. 向way0的一个set/word写入指定数据；
  // 2. 对同一set/word发起同步读，在下一个上升沿后检查输出；
  // 3. 再写其他set和word，确认两类索引没有互换；
  // 4. read_enable_i=0保持一拍，确认输出保持不变。

endmodule
