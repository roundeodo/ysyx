// I-cache元数据存储阵列。
//
// 本模块只保存每个set、每个way的tag和line-present位，并提供同步读口和受控写口。
// 命中判断、miss状态和invalidate遍历都不属于本模块。保持这种边界后，
// 当前触发器阵列可以独立替换成SRAM宏，而不需要改写I-cache控制路径。
module riscv32_icache_tag_array
  import riscv32_pkg::*;
#(
    parameter int unsigned SET_COUNT = ICACHE_SET_COUNT,
    parameter int unsigned WAY_COUNT = ICACHE_WAY_COUNT
) (
    input logic clk_i,
    input logic rst_ni,

    input  logic                              read_enable_i,
    input  icache_set_index_t                 read_set_index_i,
    output icache_tag_t                       read_tag_array_o          [WAY_COUNT],
    output logic              [WAY_COUNT-1:0] read_line_present_vector_o,

    input logic              metadata_write_valid_i,
    input icache_set_index_t metadata_write_set_index_i,
    input icache_way_index_t metadata_write_way_index_i,
    input icache_tag_t       metadata_write_tag_i,
    input logic              metadata_write_line_present_i
);

  // tag不需要复位，因为present=0时tag没有语义。不要把tag和present打成一个大
  // struct后对整个阵列复位，否则综合为SRAM时会因为复位要求失去宏推断机会。
  icache_tag_t                 tag_array_q                [WAY_COUNT] [SET_COUNT];
  logic                        line_present_array_q       [WAY_COUNT] [SET_COUNT];

  icache_tag_t                 read_tag_array_q           [WAY_COUNT];
  logic        [WAY_COUNT-1:0] read_line_present_vector_q;

  // 输出直接连接同步读出寄存器，不再增加一级寄存器。
  // read_enable_i=0时，read_*_q保持上一次结果。I-cache顶层只能在与该次array read
  // 对齐的pipeline present位有效时使用这些输出，不能把“保留旧值”误判为新查询结果。
  for (genvar way_index = 0; way_index < WAY_COUNT; way_index++) begin : gen_read_tag_output
    assign read_tag_array_o[way_index] = read_tag_array_q[way_index];
  end

  assign read_line_present_vector_o = read_line_present_vector_q;

  // 本同步读决定I-cache至少需要一个array-read阶段。不要改成组合读来伪造零延迟，
  // 因为未来替换成真实SRAM宏时组合读接口通常不存在。
  always_ff @(posedge clk_i) begin
    if (read_enable_i) begin
      for (int unsigned way_index = 0; way_index < WAY_COUNT; way_index++) begin
        read_tag_array_q[way_index]           <= tag_array_q[way_index][read_set_index_i];
        read_line_present_vector_q[way_index] <= line_present_array_q[way_index][read_set_index_i];
      end
    end
  end

  // 写口：清 present 使旧 tag 失效；安装时同时更新 tag 和 present。
  // blocking cache 不并发接收 refill 期间的查询，不依赖同地址读写旁路。
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned way_index = 0; way_index < WAY_COUNT; way_index++) begin
        for (int unsigned set_index = 0; set_index < SET_COUNT; set_index++) begin
          line_present_array_q[way_index][set_index] <= 1'b0;
        end
      end
    end else if (metadata_write_valid_i) begin
      line_present_array_q[metadata_write_way_index_i][metadata_write_set_index_i]
          <= metadata_write_line_present_i;
      if (metadata_write_line_present_i) begin
        tag_array_q[metadata_write_way_index_i][metadata_write_set_index_i] <= metadata_write_tag_i;
      end
    end
  end

endmodule
