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

  // 输出直接连接同步读出寄存器，不再增加一级寄存器。
  // read_enable_i=0时，read_*_q保持上一次结果。I-cache顶层只能在与该次array read
  // 对齐的pipeline present位有效时使用这些输出，不能把“保留旧值”误判为新查询结果。
  for (genvar way_index = 0; way_index < WAY_COUNT; way_index++) begin : gen_read_tag_output
    assign read_tag_array_o[way_index] = read_tag_array_q[way_index];
  end

  assign read_line_present_vector_o = read_line_present_vector_q;

  // 这里存在写入，只是写入对象是cache line的“身份和有效性”，不是指令数据：
  // - `tag_array_q[way][set]`说明该槽位当前保存哪一个物理地址line；
  // - `line_present_array_q[way][set]`说明这个tag对应的数据是否已经完整可用；
  // - 真正的指令word由`riscv32_icache_data_array`的refill写口写入。
  //
  // refill时两类阵列的写入顺序必须满足：每收到一个成功的refill response，data array
  // 写入一个word；只有最后一个word也成功写入后，miss unit才在同一拍或下一拍通过
  // 本模块写入tag并把present置1。这样lookup永远不会命中只填了一部分的数据line。
  // access fault和uncached fetch都不得写present=1。
  //
  // present写0用于invalidate，此时新tag没有语义，所以无需改写tag阵列。当前接口每拍
  // 只能更新一个way，因此I-cache invalidate控制器必须遍历(set, way)，不能声称每拍
  // 同时清除一个set中的全部way。以后若要每拍清一个set，应另加明确的set-invalidate
  // 端口，而不是让多个模块直接驱动present阵列。
  //
  // 第一版blocking cache在metadata写入周期不接受同set lookup。未来non-blocking
  // cache需要refill broadcast或write-first
  // bypass，让同周期查询看到刚完成的metadata，而不是依赖未定义SRAM冲突行为。
  //
  // metadata写口的三种情况必须区分清楚：
  // - write_valid=0：tag和present都保持；
  // - write_valid=1、line_present=0：只清除present，旧tag保留但没有任何命中语义；
  // - write_valid=1、line_present=1：写入新tag，并把present写成1。
  // 因此present不是由write_valid直接拉高，而是被写成metadata_write_line_present_i的值。
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
        tag_array_q[metadata_write_way_index_i][metadata_write_set_index_i]
            <= metadata_write_tag_i;
      end
    end
  end

endmodule
