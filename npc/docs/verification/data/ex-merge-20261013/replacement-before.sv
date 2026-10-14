// 策略状态与S1事件更新；与tag读取同拍冻结victim，不增加流水级。
module riscv32_icache_replacement
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
#(
    parameter int unsigned POLICY = riscv_config_pkg::ICACHE_REPLACEMENT_POLICY
) (
    input  logic                                     clk_i,
    input  logic                                     rst_ni,
    input  logic                                     invalidate_i,
    input  logic                                     read_enable_i,
    input  icache_set_index_t                        read_set_i,
    output icache_way_index_t                        read_victim_o,
    input  logic                                     hit_i,
    input  logic              [ICACHE_WAY_COUNT-1:0] hit_way_vector_i,
    input  logic                                     allocate_i,
    input  icache_way_index_t                        allocate_way_i,
    input  logic                                     victim_present_i,
    input  phys_addr_t                               access_addr_i
);
  localparam int unsigned WAY_COUNT = ICACHE_WAY_COUNT;
  localparam int unsigned SET_COUNT = ICACHE_SET_COUNT;
  localparam int unsigned WAY_BITS = $clog2(WAY_COUNT);
  localparam int unsigned LINE_ADDR_BITS = PADDR_WIDTH - ICACHE_LINE_OFFSET_W;

  initial begin
    if (WAY_COUNT < 2 || POLICY < 4 || POLICY > 16)
      $fatal(1, "replacement experiment requires policy4..16 and multiple ways");
  end

  // 同一个S1槽只产生hit或分配事件。按实际握手更新，不按valid重复更新。
  logic                                   access_event;
  icache_set_index_t                      access_set_index;
  icache_way_index_t                      access_way_index;
  logic              [LINE_ADDR_BITS-1:0] access_line_addr;
  assign access_event = hit_i || allocate_i;
  assign access_set_index = (SET_COUNT == 1) ? '0 :
      icache_set_index_t'(access_addr_i >> ICACHE_LINE_OFFSET_W);
  assign access_line_addr = access_addr_i[PADDR_WIDTH-1:ICACHE_LINE_OFFSET_W];
  always_comb begin
    access_way_index = allocate_way_i;
    if (hit_i) begin
      for (int way = 0; way < WAY_COUNT; way++) begin
        if (hit_way_vector_i[way])
          access_way_index = icache_way_index_t'(way);
      end
    end
  end

  generate
    if ((POLICY == 4 || POLICY == 5) && WAY_COUNT == 2) begin : g_two_way_lru
      logic victim_array_q[SET_COUNT];
      logic victim_array_d[SET_COUNT];
      always_comb begin
        for (int set_index = 0; set_index < SET_COUNT; set_index++) begin
          victim_array_d[set_index] = victim_array_q[set_index];
          if (access_event && access_set_index == icache_set_index_t'(set_index))
            victim_array_d[set_index] = !access_way_index[0];
        end
      end
      always_ff @(posedge clk_i) begin
        if (read_enable_i)
          read_victim_o <= icache_way_index_t'(victim_array_d[read_set_i]);
        for (int set_index = 0; set_index < SET_COUNT; set_index++) begin
          if (!rst_ni || invalidate_i)
            victim_array_q[set_index] <= 1'b0;
          else
            victim_array_q[set_index] <= victim_array_d[set_index];
        end
      end
    end else if (POLICY == 4) begin : g_lru
      logic              [WAY_BITS-1:0] age_array_q       [SET_COUNT][WAY_COUNT];
      logic              [WAY_BITS-1:0] age_array_d       [SET_COUNT][WAY_COUNT];
      icache_way_index_t                read_victim_index;

      always_comb begin
        for (int set_index = 0; set_index < SET_COUNT; set_index++) begin
          for (int way = 0; way < WAY_COUNT; way++) begin
            age_array_d[set_index][way] = age_array_q[set_index][way];
            if (access_event && access_set_index == icache_set_index_t'(set_index)) begin
              if (access_way_index == icache_way_index_t'(way))
                age_array_d[set_index][way] = '0;
              else if (age_array_q[set_index][way] < age_array_q[set_index][access_way_index])
                age_array_d[set_index][way] = age_array_q[set_index][way] + 1'b1;
            end
          end
        end
        read_victim_index = '0;
        for (int way = 1; way < WAY_COUNT; way++) begin
          if (age_array_d[read_set_i][way] > age_array_d[read_set_i][read_victim_index])
            read_victim_index = icache_way_index_t'(way);
        end
      end
      always_ff @(posedge clk_i) begin
        if (read_enable_i)
          read_victim_o <= read_victim_index;
        for (int set_index = 0; set_index < SET_COUNT; set_index++) begin
          for (int way = 0; way < WAY_COUNT; way++) begin
            if (!rst_ni || invalidate_i)
              age_array_q[set_index][way] <= WAY_BITS'(WAY_COUNT - 1);
            else
              age_array_q[set_index][way] <= age_array_d[set_index][way];
          end
        end
      end
    end else if (POLICY == 5) begin : g_plru
      logic              [WAY_COUNT-2:0] tree_array_q      [SET_COUNT];
      logic              [WAY_COUNT-2:0] tree_array_d      [SET_COUNT];
      icache_way_index_t                 read_victim_index;
      integer update_node_index, read_node_index;
      logic direction;

      always_comb begin
        for (int set_index = 0; set_index < SET_COUNT; set_index++)
          tree_array_d[set_index] = tree_array_q[set_index];
        update_node_index = 0;
        for (int depth = 0; depth < WAY_BITS; depth++) begin
          if (access_event)
            tree_array_d[access_set_index][update_node_index] = !access_way_index[WAY_BITS-1-depth];
          update_node_index = 2 * update_node_index + 1 + int'(access_way_index[WAY_BITS-1-depth]);
        end
        read_node_index   = 0;
        read_victim_index = '0;
        direction         = 1'b0;
        for (int depth = 0; depth < WAY_BITS; depth++) begin
          direction                           = tree_array_d[read_set_i][read_node_index];
          read_victim_index[WAY_BITS-1-depth] = direction;
          read_node_index                     = 2 * read_node_index + 1 + int'(direction);
        end
      end
      always_ff @(posedge clk_i) begin
        if (read_enable_i)
          read_victim_o <= read_victim_index;
        for (int set_index = 0; set_index < SET_COUNT; set_index++) begin
          if (!rst_ni || invalidate_i)
            tree_array_q[set_index] <= '0;
          else
            tree_array_q[set_index] <= tree_array_d[set_index];
        end
      end
    end else if (POLICY == 6) begin : g_random
      logic [31:0] random_q, random_d;
      always_comb begin
        random_d = random_q;
        if (allocate_i) begin
          random_d ^= random_d << 13;
          random_d ^= random_d >> 17;
          random_d ^= random_d << 5;
        end
      end
      always_ff @(posedge clk_i) begin
        if (!rst_ni || invalidate_i)
          random_q <= 32'd97531;
        else
          random_q <= random_d;
        if (read_enable_i)
          read_victim_o <= icache_way_index_t'(random_d);
      end
    end else begin : g_rrip
      localparam bit SEGMENT_REUSE = (POLICY >= 9 && POLICY <= 11) || POLICY == 13 || POLICY >= 15;
      localparam bit REUSE_FEEDBACK = POLICY == 10 || POLICY == 11 || POLICY >= 15;
      localparam bit PATH_SIGNATURE = POLICY == 11 || POLICY == 15;
      localparam bit QUERY_BYPASS = POLICY >= 13;
      localparam int unsigned LEADER_STRIDE = (SET_COUNT >= 32) ? 32 : ((SET_COUNT >= 4) ? SET_COUNT : 4);
      logic [1:0] rrpv_array_q[SET_COUNT][WAY_COUNT], rrpv_array_d[SET_COUNT][WAY_COUNT];
      logic [4:0] insertion_count_q, insertion_count_d;
      logic [9:0] selector_q, selector_d;
      logic [LINE_ADDR_BITS-1:0] previous_line_q;
      logic                      previous_line_present_q;
      logic [              15:0] history_q;
      logic [5:0] signature_array_q[SET_COUNT][WAY_COUNT], signature_array_d[SET_COUNT][WAY_COUNT];
      logic reused_array_q[SET_COUNT][WAY_COUNT], reused_array_d[SET_COUNT][WAY_COUNT];
      logic [1:0] prediction_array_q[64], prediction_array_d[64];
      logic segment_start, bimodal;
      logic [5:0] signature;
      logic [1:0] maximum_rrpv, age_amount, insertion;
      logic              [          1:0] read_rrpv_array    [WAY_COUNT];
      logic              [WAY_COUNT-1:0] read_winner_vector;
      icache_way_index_t                 read_victim_index;

      // 当前行地址发生变化时，开始新的访问段。
      assign segment_start = !previous_line_present_q || previous_line_q != access_line_addr;
      assign signature = 6'(access_line_addr ^ (access_line_addr >> 6)) ^
          (PATH_SIGNATURE ? history_q[5:0] : 6'd0);

      // 先训练旧身份，再查新签名，覆盖同索引训练/插入的旁路。每拍最多一次训练。
      always_comb begin
        for (int index = 0; index < 64; index++)
          prediction_array_d[index] = prediction_array_q[index];
        for (int set_index = 0; set_index < SET_COUNT; set_index++) begin
          for (int way = 0; way < WAY_COUNT; way++) begin
            signature_array_d[set_index][way] = signature_array_q[set_index][way];
            reused_array_d[set_index][way]    = reused_array_q[set_index][way];
          end
        end
        if (REUSE_FEEDBACK && allocate_i) begin
          if (victim_present_i && !reused_array_q[access_set_index][access_way_index] &&
              prediction_array_q[signature_array_q[access_set_index][access_way_index]] != 0)
            prediction_array_d[signature_array_q[access_set_index][access_way_index]] =
                prediction_array_q[signature_array_q[access_set_index][access_way_index]] - 1'b1;
          signature_array_d[access_set_index][access_way_index] = signature;
          reused_array_d[access_set_index][access_way_index]    = 1'b0;
        end else if (REUSE_FEEDBACK && hit_i && segment_start &&
                     !reused_array_q[access_set_index][access_way_index]) begin
          if (prediction_array_q[signature_array_q[access_set_index][access_way_index]] != 3)
            prediction_array_d[signature_array_q[access_set_index][access_way_index]] =
                prediction_array_q[signature_array_q[access_set_index][access_way_index]] + 1'b1;
          reused_array_d[access_set_index][access_way_index] = 1'b1;
        end
      end

      always_comb begin
        insertion_count_d = insertion_count_q;
        selector_d        = selector_q;
        bimodal           = POLICY == 7;
        if (allocate_i)
          insertion_count_d = insertion_count_q + 1'b1;
        if (POLICY == 8) begin
          if (int'(access_set_index) % LEADER_STRIDE == 0) begin
            if (allocate_i && selector_q != 1023)
              selector_d = selector_q + 1'b1;
            bimodal = 1'b0;
          end else if (int'(access_set_index) % LEADER_STRIDE == LEADER_STRIDE - 1) begin
            if (allocate_i && selector_q != 0)
              selector_d = selector_q - 1'b1;
            bimodal = 1'b1;
        end else
          bimodal = selector_q >= 512;
        end
        insertion = (bimodal && insertion_count_d != 0) ? 2'd3 : 2'd2;
        if (REUSE_FEEDBACK)
          insertion = prediction_array_d[signature] == 0 ? 2'd3 : 2'd2;
        maximum_rrpv = rrpv_array_q[access_set_index][0];
        for (int way = 1; way < WAY_COUNT; way++) begin
          if (rrpv_array_q[access_set_index][way] > maximum_rrpv)
            maximum_rrpv = rrpv_array_q[access_set_index][way];
        end
        age_amount = victim_present_i ? 2'd3 - maximum_rrpv : 2'd0;
        for (int set_index = 0; set_index < SET_COUNT; set_index++) begin
          for (int way = 0; way < WAY_COUNT; way++) begin
            rrpv_array_d[set_index][way] = rrpv_array_q[set_index][way];
            if (access_set_index == icache_set_index_t'(set_index)) begin
              if (allocate_i) begin
                rrpv_array_d[set_index][way] = rrpv_array_q[set_index][way] + age_amount;
                if (access_way_index == icache_way_index_t'(way))
                  rrpv_array_d[set_index][way] = insertion;
              end else if (hit_i && access_way_index == icache_way_index_t'(way) &&
                           (!SEGMENT_REUSE || segment_start))
                rrpv_array_d[set_index][way] = 2'd0;
            end
          end
        end
        // 阻塞式cache的miss分配与新查询互斥；13～16只保留真实的同组hit前递。
        for (int way = 0; way < WAY_COUNT; way++) begin
          read_rrpv_array[way] = rrpv_array_d[read_set_i][way];
          if (QUERY_BYPASS) begin
            read_rrpv_array[way] = rrpv_array_q[read_set_i][way];
            if (hit_i && access_set_index == read_set_i && access_way_index == icache_way_index_t'(way) &&
                (!SEGMENT_REUSE || segment_start))
              read_rrpv_array[way] = 2'd0;
          end
        end
        read_victim_index  = '0;
        read_winner_vector = '0;
        if (QUERY_BYPASS && WAY_COUNT <= 4) begin
          // 各路并行比较，平局选最小路号；不再串联victim编码与RRPV索引。
          for (int way = 0; way < WAY_COUNT; way++) begin
            read_winner_vector[way] = 1'b1;
            for (int other = 0; other < WAY_COUNT; other++) begin
              if (other < way)
                read_winner_vector[way] &= read_rrpv_array[way] > read_rrpv_array[other];
              else if (other > way)
                read_winner_vector[way] &= read_rrpv_array[way] >= read_rrpv_array[other];
            end
            read_victim_index |= icache_way_index_t'(way) & {WAY_BITS{read_winner_vector[way]}};
          end
        end else begin
          for (int way = 1; way < WAY_COUNT; way++) begin
            if (read_rrpv_array[way] > read_rrpv_array[read_victim_index])
              read_victim_index = icache_way_index_t'(way);
          end
        end
      end

      always_ff @(posedge clk_i) begin
        if (read_enable_i)
          read_victim_o <= read_victim_index;
        if (!rst_ni || invalidate_i) begin
          insertion_count_q       <= '0;
          selector_q              <= 10'd511;
          previous_line_q         <= '0;
          previous_line_present_q <= 1'b0;
          history_q               <= '0;
        end else begin
          insertion_count_q <= insertion_count_d;
          selector_q        <= selector_d;
          if (access_event) begin
            previous_line_q         <= access_line_addr;
            previous_line_present_q <= 1'b1;
            if (segment_start)
              history_q <= (history_q << 3) ^ {13'd0, access_line_addr[2:0]};
          end
        end
        for (int index = 0; index < 64; index++) begin
          if (!rst_ni || invalidate_i)
            prediction_array_q[index] <= 2'd1;
          else
            prediction_array_q[index] <= prediction_array_d[index];
        end
        for (int set_index = 0; set_index < SET_COUNT; set_index++) begin
          for (int way = 0; way < WAY_COUNT; way++) begin
            if (!rst_ni || invalidate_i) begin
              rrpv_array_q[set_index][way]      <= 2'd3;
              signature_array_q[set_index][way] <= '0;
              reused_array_q[set_index][way]    <= 1'b0;
            end else begin
              rrpv_array_q[set_index][way]      <= rrpv_array_d[set_index][way];
              signature_array_q[set_index][way] <= signature_array_d[set_index][way];
              reused_array_q[set_index][way]    <= reused_array_d[set_index][way];
            end
          end
        end
      end
    end
  endgenerate

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni) !(hit_i && allocate_i));
  assert property (@(posedge clk_i) disable iff (!rst_ni) hit_i |-> $onehot(hit_way_vector_i));
  if (POLICY >= 13) begin : g_check_blocking_query
    assert property (@(posedge clk_i) disable iff (!rst_ni) !(read_enable_i && allocate_i));
  end
`endif
endmodule
