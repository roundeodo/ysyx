// 分段访问RRIP（源实验策略13）。仅保存替换状态，与tag读口同拍冻结候选路。
// 同一行内的连续取指不提升优先级，离开后再次命中才将RRPV置零。
module riscv_icache_replacement
  import riscv_pkg::*;
  import riscv_addr_map_pkg::*;
(
    input  logic                                     clk_i,
    input  logic                                     rst_ni,
    input  logic                                     invalidate_i,
    input  logic                                     read_enable_i,
    input  icache_set_index_t                        read_set_index_i,
    output icache_way_index_t                        read_victim_way_index_o,
    input  logic                                     hit_i,
    input  logic              [ICACHE_WAY_COUNT-1:0] hit_way_vector_i,
    input  logic                                     allocate_i,
    input  icache_way_index_t                        allocate_way_index_i,
    input  logic                                     victim_present_i,
    input  phys_addr_t                               access_addr_i
);
  localparam int unsigned LINE_ADDRESS_WIDTH = PADDR_WIDTH - ICACHE_LINE_OFFSET_W;

  initial begin
    if (ICACHE_WAY_COUNT < 2) $fatal(1, "segmented RRIP requires multiple ways");
  end

  logic access_occurred;
  icache_set_index_t access_set_index;
  logic [LINE_ADDRESS_WIDTH-1:0] access_line_address;
  logic [LINE_ADDRESS_WIDTH-1:0] previous_line_address_q;
  logic previous_line_present_q;
  logic access_starts_segment;

  assign access_occurred = hit_i || allocate_i;
  assign access_set_index = (ICACHE_SET_COUNT == 1) ? '0 :
                           icache_set_index_t'(access_addr_i >> ICACHE_LINE_OFFSET_W);
  assign access_line_address = access_addr_i[PADDR_WIDTH-1:ICACHE_LINE_OFFSET_W];
  assign access_starts_segment = !previous_line_present_q ||
                                previous_line_address_q != access_line_address;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || invalidate_i) begin
      previous_line_address_q <= '0;
      previous_line_present_q <= 1'b0;
    end else if (access_occurred) begin
      previous_line_address_q <= access_line_address;
      previous_line_present_q <= 1'b1;
    end
  end

  // RRPV越大越优先替换。仅替换有效行时老化整组，新行插入值为2。
  logic [1:0] rrpv_array_q [ICACHE_SET_COUNT][ICACHE_WAY_COUNT];
  logic [1:0] rrpv_array_d [ICACHE_SET_COUNT][ICACHE_WAY_COUNT];
  logic [1:0] maximum_rrpv;
  logic [1:0] age_amount;

  always_comb begin
    maximum_rrpv = rrpv_array_q[access_set_index][0];
    for (int unsigned way_index = 1; way_index < ICACHE_WAY_COUNT; way_index++) begin
      if (rrpv_array_q[access_set_index][way_index] > maximum_rrpv)
        maximum_rrpv = rrpv_array_q[access_set_index][way_index];
    end
    age_amount = victim_present_i ? 2'd3 - maximum_rrpv : 2'd0;

    for (int unsigned set_index = 0; set_index < ICACHE_SET_COUNT; set_index++) begin
      for (int unsigned way_index = 0; way_index < ICACHE_WAY_COUNT; way_index++) begin
        rrpv_array_d[set_index][way_index] = rrpv_array_q[set_index][way_index];
        if (access_set_index == icache_set_index_t'(set_index)) begin
          if (allocate_i) begin
            rrpv_array_d[set_index][way_index] = rrpv_array_q[set_index][way_index] + age_amount;
            if (allocate_way_index_i == icache_way_index_t'(way_index))
              rrpv_array_d[set_index][way_index] = 2'd2;
          end else if (hit_i && hit_way_vector_i[way_index] && access_starts_segment) begin
            rrpv_array_d[set_index][way_index] = 2'd0;
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    for (int unsigned set_index = 0; set_index < ICACHE_SET_COUNT; set_index++) begin
      for (int unsigned way_index = 0; way_index < ICACHE_WAY_COUNT; way_index++) begin
        if (!rst_ni || invalidate_i) rrpv_array_q[set_index][way_index] <= 2'd3;
        else rrpv_array_q[set_index][way_index] <= rrpv_array_d[set_index][way_index];
      end
    end
  end

  // 查询与miss分配互斥，只需前递同组命中提升。该路径不经过整组老化逻辑。
  logic [1:0] read_rrpv_array[ICACHE_WAY_COUNT];
  icache_way_index_t read_victim_way_index;

  always_comb begin
    for (int unsigned way_index = 0; way_index < ICACHE_WAY_COUNT; way_index++) begin
      read_rrpv_array[way_index] = rrpv_array_q[read_set_index_i][way_index];
      if (hit_i && access_set_index == read_set_index_i && hit_way_vector_i[way_index] &&
          access_starts_segment)
        read_rrpv_array[way_index] = 2'd0;
    end
    read_victim_way_index = '0;
    for (int unsigned way_index = 1; way_index < ICACHE_WAY_COUNT; way_index++) begin
      if (read_rrpv_array[way_index] > read_rrpv_array[read_victim_way_index])
        read_victim_way_index = icache_way_index_t'(way_index);
    end
  end

  // 与tag读结果对齐；无新查询时保持。首次有效查询之前不消费这个快照。
  always_ff @(posedge clk_i) begin
    if (read_enable_i) read_victim_way_index_o <= read_victim_way_index;
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni) !(hit_i && allocate_i));
  assert property (@(posedge clk_i) disable iff (!rst_ni) hit_i |-> $onehot(hit_way_vector_i));
  assert property (@(posedge clk_i) disable iff (!rst_ni) !(read_enable_i && allocate_i));
`endif
endmodule : riscv_icache_replacement
