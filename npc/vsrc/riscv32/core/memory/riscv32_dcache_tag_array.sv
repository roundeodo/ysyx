// D-cache元数据阵列：每个set/way保存tag、present和dirty。
//
// 命中比较、替换和写回调度属于D-cache控制器；本模块只提供同步读和单个元数据写口。
// tag数据不复位，present=0时tag和dirty均没有命中语义，便于后续替换成SRAM宏。
module riscv32_dcache_tag_array
  import riscv32_pkg::*;
#(
    parameter int unsigned SET_COUNT = DCACHE_SET_COUNT,
    parameter int unsigned WAY_COUNT = DCACHE_WAY_COUNT
) (
    input logic clk_i,
    input logic rst_ni,

    input  logic                              read_enable_i,
    input  dcache_set_index_t                 read_set_index_i,
    output dcache_tag_t                       read_tag_array_o         [WAY_COUNT],
    output logic              [WAY_COUNT-1:0] read_line_present_vector_o,
    output logic              [WAY_COUNT-1:0] read_line_dirty_vector_o,

    input logic              metadata_write_valid_i,
    input dcache_set_index_t metadata_write_set_index_i,
    input dcache_way_index_t metadata_write_way_index_i,
    input dcache_tag_t       metadata_write_tag_i,
    input logic              metadata_write_line_present_i,
    input logic              metadata_write_line_dirty_i
);

  dcache_tag_t tag_array_q[WAY_COUNT][SET_COUNT];
  logic line_present_array_q[WAY_COUNT][SET_COUNT];
  logic line_dirty_array_q[WAY_COUNT][SET_COUNT];

  dcache_tag_t read_tag_array_q[WAY_COUNT];
  logic [WAY_COUNT-1:0] read_line_present_vector_q;
  logic [WAY_COUNT-1:0] read_line_dirty_vector_q;

  always_ff @(posedge clk_i) begin
    if (read_enable_i) begin
      for (int unsigned way_index = 0; way_index < WAY_COUNT; way_index++) begin
        read_tag_array_q[way_index] <= tag_array_q[way_index][read_set_index_i];
        read_line_present_vector_q[way_index] <=
            line_present_array_q[way_index][read_set_index_i];
        read_line_dirty_vector_q[way_index] <=
            line_dirty_array_q[way_index][read_set_index_i];
      end
    end
  end

  for (genvar way_index = 0; way_index < WAY_COUNT; way_index++) begin : gen_read_outputs
    assign read_tag_array_o[way_index] = read_tag_array_q[way_index];
  end
  assign read_line_present_vector_o = read_line_present_vector_q;
  assign read_line_dirty_vector_o = read_line_dirty_vector_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned way_index = 0; way_index < WAY_COUNT; way_index++) begin
        for (int unsigned set_index = 0; set_index < SET_COUNT; set_index++) begin
          line_present_array_q[way_index][set_index] <= 1'b0;
          line_dirty_array_q[way_index][set_index] <= 1'b0;
        end
      end
    end else if (metadata_write_valid_i) begin
      line_present_array_q[metadata_write_way_index_i][metadata_write_set_index_i]
          <= metadata_write_line_present_i;
      line_dirty_array_q[metadata_write_way_index_i][metadata_write_set_index_i]
          <= metadata_write_line_present_i && metadata_write_line_dirty_i;
      if (metadata_write_line_present_i) begin
        tag_array_q[metadata_write_way_index_i][metadata_write_set_index_i]
            <= metadata_write_tag_i;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (SET_COUNT > 0) else $fatal(1, "D-cache set count must be positive");
    assert (WAY_COUNT > 0) else $fatal(1, "D-cache way count must be positive");
  end
`endif

endmodule
