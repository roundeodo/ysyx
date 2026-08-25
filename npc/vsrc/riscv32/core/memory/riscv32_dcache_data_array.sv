// D-cache数据阵列，按way、line内word和set组织。
//
// 同步读口并行读出所有way的目标word；字节写口同时服务store hit和line refill。
// byte strobe是实现sb/sh/sw/sd以及未来store merge的必要语义，不属于AXI接口细节。
module riscv32_dcache_data_array
  import riscv32_pkg::*;
#(
    parameter int unsigned SET_COUNT      = DCACHE_SET_COUNT,
    parameter int unsigned WAY_COUNT      = DCACHE_WAY_COUNT,
    parameter int unsigned WORDS_PER_LINE = DCACHE_WORDS_PER_LINE
) (
    input logic clk_i,
    input logic rst_ni,

    input  logic               read_enable_i,
    input  dcache_set_index_t  read_set_index_i,
    input  dcache_word_index_t read_word_index_i,
    output core_data_t         read_word_data_array_o[WAY_COUNT],

    input logic               write_valid_i,
    input dcache_set_index_t  write_set_index_i,
    input dcache_way_index_t  write_way_index_i,
    input dcache_word_index_t write_word_index_i,
    input core_data_t         write_word_data_i,
    input core_byte_strobe_t  write_byte_strobe_i
);

  core_data_t data_array_q[WAY_COUNT][WORDS_PER_LINE][SET_COUNT];
  core_data_t read_word_data_array_q[WAY_COUNT];

  // 写事务先在上升沿进入staging寄存器，随后在低电平写入锁存阵列。这样保持
  // 同步读接口和byte strobe语义不变，同时避免把整个小容量cache描述成带写使能
  // 的触发器阵列。未来替换为带byte-enable的SRAM宏时，仅需修改本模块内部实现。
  dcache_set_index_t staged_write_set_index_q;
  dcache_way_index_t staged_write_way_index_q;
  dcache_word_index_t staged_write_word_index_q;
  core_data_t staged_write_word_data_q;
  core_byte_strobe_t staged_write_byte_strobe_q;
  logic staged_write_enable_q;

  // 同步读时序与真实单周期SRAM宏一致。顶层必须用S1 present限定这些保留型输出。
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
  // 当前blocking设计保证lookup和写回采集不会与本写口访问同一line；未来hit-under-miss
  // 必须在D-cache顶层增加refill/store bypass，不能依赖工艺相关的read-during-write行为。
  always_ff @(posedge clk_i) begin
    if (write_valid_i) begin
      staged_write_set_index_q   <= write_set_index_i;
      staged_write_way_index_q   <= write_way_index_i;
      staged_write_word_index_q  <= write_word_index_i;
      staged_write_word_data_q   <= write_word_data_i;
      staged_write_byte_strobe_q <= write_byte_strobe_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      staged_write_enable_q <= 1'b0;
    end else begin
      staged_write_enable_q <= write_valid_i;
    end
  end

  always_latch begin
    if (!clk_i && staged_write_enable_q) begin
      for (int unsigned byte_index = 0; byte_index < CORE_DATA_BYTE_COUNT; byte_index++) begin
        if (staged_write_byte_strobe_q[byte_index]) begin
          data_array_q[staged_write_way_index_q]
                      [staged_write_word_index_q]
                      [staged_write_set_index_q]
                      [byte_index*8+:8] = staged_write_word_data_q[byte_index*8+:8];
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (WORDS_PER_LINE > 0)
      else $fatal(1, "D-cache line must contain at least one core data word");
  end
`endif

endmodule
