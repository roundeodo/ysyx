// I-cache元数据存储阵列。
//
// 本模块只保存每个set、每个way的tag和line-present位，并提供同步读口和受控写口。
// 命中判断和 miss 状态由上层负责；有效位独立于 tag/data，一次清除即可失效全表。
module riscv32_icache_tag_array
  import riscv32_pkg::*;
#(
    parameter int unsigned SET_COUNT = ICACHE_SET_COUNT,
    parameter int unsigned WAY_COUNT = ICACHE_WAY_COUNT
) (
    input logic clk_i,
    input logic rst_ni,
    input logic invalidate_all_i,

    input  logic                              read_enable_i,
    input  icache_set_index_t                 read_set_index_i,
    output icache_tag_t                       read_tag_array_o          [WAY_COUNT],
    output logic              [WAY_COUNT-1:0] read_line_present_vector_o,

    // 实验替换元数据与tag同拍读取；退休匹配复用现有tag，不复制整张地址表。
    output logic [1:0] read_rrpv_array_o [WAY_COUNT],
    input logic age_valid_i,
    input icache_set_index_t age_set_index_i,
    input logic [1:0] age_amount_i,
    input logic hit_valid_i,
    input icache_set_index_t hit_set_index_i,
    input logic [WAY_COUNT-1:0] hit_way_vector_i,
    input logic retired_valid_i,
    input program_counter_t retired_pc_i,

    input logic              metadata_write_valid_i,
    input icache_set_index_t metadata_write_set_index_i,
    input icache_way_index_t metadata_write_way_index_i,
    input icache_tag_t       metadata_write_tag_i,
    input logic              metadata_write_line_present_i
);

  localparam int unsigned REPLACEMENT_POLICY = riscv_config_pkg::ICACHE_REPLACEMENT_POLICY;
  initial begin
    if (REPLACEMENT_POLICY > 16 || (REPLACEMENT_POLICY != 0 && WAY_COUNT < 2))
      $fatal(1, "experimental I-cache replacement requires multiple ways and policy 1..16");
  end

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

  // 替换状态：同步快照保证受阻请求的victim不会被后续退休提示改变。
  generate
    if (REPLACEMENT_POLICY >= 1 && REPLACEMENT_POLICY <= 3) begin : g_rrip
      logic [1:0] rrpv_array_q [WAY_COUNT][SET_COUNT];
      logic [1:0] rrpv_array_d [WAY_COUNT][SET_COUNT];
      logic [1:0] read_rrpv_array_q [WAY_COUNT];
      icache_set_index_t retired_set_index;
      icache_tag_t retired_tag;
      assign retired_set_index = (SET_COUNT == 1) ? '0 :
          icache_set_index_t'(retired_pc_i >> ICACHE_LINE_OFFSET_W);
      assign retired_tag = icache_tag_t'(retired_pc_i >> (ICACHE_LINE_OFFSET_W + ICACHE_SET_INDEX_BITS));

      for (genvar way = 0; way < WAY_COUNT; way++) begin : g_read
        assign read_rrpv_array_o[way] = read_rrpv_array_q[way];
        always_ff @(posedge clk_i) begin
          if (read_enable_i)
            read_rrpv_array_q[way] <= rrpv_array_q[way][read_set_index_i];
        end
      end

      always_comb begin
        for (int way = 0; way < WAY_COUNT; way++) begin
          for (int set_index = 0; set_index < SET_COUNT; set_index++) begin
            rrpv_array_d[way][set_index] = rrpv_array_q[way][set_index];
            if (age_valid_i && age_set_index_i == icache_set_index_t'(set_index)) begin
              if ({1'b0, rrpv_array_q[way][set_index]} + {1'b0, age_amount_i} >= 3)
                rrpv_array_d[way][set_index] = 2'd3;
              else
                rrpv_array_d[way][set_index] = rrpv_array_q[way][set_index] + age_amount_i;
            end
            if (hit_valid_i && hit_set_index_i == icache_set_index_t'(set_index) && hit_way_vector_i[way] &&
                (REPLACEMENT_POLICY != 3 || rrpv_array_q[way][set_index] != 2'd3))
              rrpv_array_d[way][set_index] = 2'd0;
            if (REPLACEMENT_POLICY == 3 && retired_valid_i && retired_set_index == icache_set_index_t'(set_index) &&
                line_present_array_q[way][set_index] && tag_array_q[way][set_index] == retired_tag)
              rrpv_array_d[way][set_index] = 2'd0;
            // 新分配的身份优先于旧行退休；安装同tag可接收当拍提示。
            if (metadata_write_valid_i && metadata_write_way_index_i == icache_way_index_t'(way) &&
                metadata_write_set_index_i == icache_set_index_t'(set_index)) begin
              rrpv_array_d[way][set_index] = (REPLACEMENT_POLICY == 1) ? 2'd2 : 2'd3;
              if (REPLACEMENT_POLICY == 3 && metadata_write_line_present_i && retired_valid_i &&
                  retired_set_index == metadata_write_set_index_i && retired_tag == metadata_write_tag_i)
                rrpv_array_d[way][set_index] = 2'd0;
            end
          end
        end
      end
      always_ff @(posedge clk_i) begin
        for (int way = 0; way < WAY_COUNT; way++) begin
          for (int set_index = 0; set_index < SET_COUNT; set_index++) begin
            if (!rst_ni || invalidate_all_i)
              rrpv_array_q[way][set_index] <= 2'd3;
            else
              rrpv_array_q[way][set_index] <= rrpv_array_d[way][set_index];
          end
        end
      end
    end else begin : g_no_rrip
      for (genvar way = 0; way < WAY_COUNT; way++) begin : g_read
        assign read_rrpv_array_o[way] = 2'd0;
      end
    end
  endgenerate

  // 写口：清 present 使旧 tag 失效；安装时同时更新 tag 和 present。
  // blocking cache 不并发接收 refill 期间的查询，不依赖同地址读写旁路。
  always_ff @(posedge clk_i) begin
    if (!rst_ni || invalidate_all_i) begin
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
