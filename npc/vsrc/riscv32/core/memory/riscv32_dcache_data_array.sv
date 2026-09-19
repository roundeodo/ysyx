// D-cache数据阵列，按way、line内word和set组织。
//
// 同步读口并行读出所有way的目标word；字节写口同时服务store hit和line refill。
// 字节掩码只控制指定字节的写入，未选中字节保持原值。
module riscv32_dcache_data_array
  import riscv32_pkg::*;
#(
    parameter int unsigned SET_COUNT      = DCACHE_SET_COUNT,
    parameter int unsigned WAY_COUNT      = DCACHE_WAY_COUNT,
    parameter int unsigned WORDS_PER_LINE = DCACHE_WORDS_PER_LINE
) (
    input  logic clk_i,

    input  logic               read_enable_i,
    input  dcache_set_index_t  read_set_index_i,
    input  dcache_word_index_t read_word_index_i,
    output core_data_t         read_word_data_array_o[WAY_COUNT],

    input  logic               write_valid_i,
    input  dcache_set_index_t  write_set_index_i,
    input  dcache_way_index_t  write_way_index_i,
    input  dcache_word_index_t write_word_index_i,
    input  core_data_t         write_word_data_i,
    input  core_byte_strobe_t  write_byte_strobe_i
);

  core_data_t data_array_q[WAY_COUNT][WORDS_PER_LINE][SET_COUNT];
  core_data_t read_word_data_array_q[WAY_COUNT];

  // 同步读在上升沿采样；禁用读口时输出保持。lookup 或 miss 采集状态解释其有效性。
  always_ff @(posedge clk_i) begin
    if (read_enable_i) begin
      for (int unsigned way_index = 0; way_index < WAY_COUNT; way_index++) begin
        read_word_data_array_q[way_index] <=
            data_array_q[way_index][read_word_index_i][read_set_index_i];
      end
    end
  end

  for (genvar way_index = 0; way_index < WAY_COUNT; way_index++) begin : gen_read_outputs
    assign read_word_data_array_o[way_index] = read_word_data_array_q[way_index];
  end

  // 每个byte lane独立写使能，使综合器能够映射到带byte-enable的SRAM或banked array。
  // RTL 同沿读写同一字时读到旧值。store 与下一 lookup 的冲突由 D-cache 顶层旁路处理；
  // 阵列本身不检测请求相关性，也不复制另一套旁路。
  always_ff @(posedge clk_i) begin
    if (write_valid_i) begin
      for (int unsigned byte_index = 0; byte_index < CORE_DATA_BYTE_COUNT; byte_index++) begin
        if (write_byte_strobe_i[byte_index]) begin
          data_array_q[write_way_index_i][write_word_index_i][write_set_index_i]
              [byte_index*8+:8] <= write_word_data_i[byte_index*8+:8];
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (WORDS_PER_LINE > 0)
      else
        $fatal(1, "D-cache line must contain at least one core data word");
  end
`endif

endmodule
