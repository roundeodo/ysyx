// I-cache tag and line-presence storage.
module riscv32_icache_tag_array
  import riscv32_pkg::*;
#(
    parameter int unsigned SET_COUNT = ICACHE_SET_COUNT,
    parameter int unsigned WAY_COUNT = ICACHE_WAY_COUNT
) (
    input logic clk_i,
    input logic rst_ni,

    input  logic               read_enable_i,
    input  icache_set_index_t  read_set_index_i,
    output icache_tag_t        read_tag_array_o[WAY_COUNT],
    output logic [WAY_COUNT-1:0] read_line_present_vector_o,

    input logic              metadata_write_valid_i,
    input icache_set_index_t metadata_write_set_index_i,
    input icache_way_index_t metadata_write_way_index_i,
    input icache_tag_t       metadata_write_tag_i,
    input logic              metadata_write_line_present_i
);

  // TODO(ICACHE-TAG-1): 在本TODO正下方声明tag和present存储阵列以及同步读出寄存器。
  // 建议数据形状如下，数组名明确表示它们是集合：
  //
  //   icache_tag_t tag_array_q [WAY_COUNT][SET_COUNT];
  //   logic        line_present_array_q [WAY_COUNT][SET_COUNT];
  //
  //   icache_tag_t         read_tag_array_q [WAY_COUNT];
  //   logic [WAY_COUNT-1:0] read_line_present_vector_q;
  //
  // tag不需要复位，因为present=0时tag没有语义。不要把tag和present打成一个大
  // struct后对整个阵列复位，否则综合为SRAM时会因为复位要求失去宏推断机会。

  // TODO(ICACHE-TAG-2): 在本TODO正下方实现同步读取。
  // read_enable_i为1的上升沿，读取所有way在read_set_index_i处的tag和present，
  // 保存到read_*_q；随后连续赋给输出。使用for循环遍历way：
  //
  //   always_ff @(posedge clk_i) begin
  //     if (read_enable_i) begin
  //       for (int unsigned way_index = 0; way_index < WAY_COUNT; way_index++) begin
  //         read_tag_array_q[way_index] <= tag_array_q[way_index][read_set_index_i];
  //         read_line_present_vector_q[way_index] <=
  //             line_present_array_q[way_index][read_set_index_i];
  //       end
  //     end
  //   end
  //
  // 本同步读决定I-cache至少需要一个array-read阶段。不要改成组合读来伪造零延迟，
  // 因为未来替换成真实SRAM宏时组合读接口通常不存在。

  // TODO(ICACHE-TAG-3): 在本TODO正下方实现metadata写入和present复位。
  // 复位时只清空所有line_present_array_q。正常运行时，metadata_write_valid_i为1
  // 才更新被选way/set的tag与present。line refill必须在整条line全部成功返回后，
  // 才写present=1；access fault或invalidate则写present=0。
  //
  // 第一版blocking cache在metadata写入周期不接受同set lookup，因此可以断言禁止
  // read/write collision。未来non-blocking cache需要refill broadcast或write-first
  // bypass，让同周期查询看到刚完成的metadata，而不是依赖未定义SRAM冲突行为。

  // TODO(ICACHE-TAG-4): 在本TODO正下方增加断言。
  // 检查read/write set和way索引不越界；检查同周期禁止的read/write collision；
  // 检查metadata_write_line_present_i=1时tag不是X。断言只能观察，不能控制接口。

endmodule
