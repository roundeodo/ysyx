// 策略状态与S1事件更新；与tag读取同拍冻结victim，不增加流水级。
module riscv32_icache_replacement
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
#(
    parameter int unsigned POLICY = riscv_config_pkg::ICACHE_REPLACEMENT_POLICY
) (
    input  logic                             clk_i,
    input  logic                             rst_ni,
    input  logic                             invalidate_i,
    input  logic                             read_enable_i,
    input  icache_set_index_t                read_set_i,
    output icache_way_index_t                read_victim_o,
    input  logic                             hit_i,
    input  logic [ICACHE_WAY_COUNT-1:0]      hit_way_vector_i,
    input  logic                             allocate_i,
    input  icache_way_index_t                allocate_way_i,
    input  logic                             victim_present_i,
    input  phys_addr_t                       access_addr_i
);
  localparam int unsigned WAYS = ICACHE_WAY_COUNT;
  localparam int unsigned SETS = ICACHE_SET_COUNT;
  localparam int unsigned WAY_BITS = $clog2(WAYS);
  localparam int unsigned LINE_ADDR_BITS = PADDR_WIDTH - ICACHE_LINE_OFFSET_W;

  initial begin
    if (WAYS < 2 || POLICY < 4 || POLICY > 16)
      $fatal(1, "replacement experiment requires policy4..16 and multiple ways");
  end

  // 同一个S1槽只产生hit或分配事件。按实际握手更新，不按valid重复更新。
  logic access_event;
  icache_set_index_t access_set;
  icache_way_index_t access_way;
  logic [LINE_ADDR_BITS-1:0] access_line;
  assign access_event = hit_i || allocate_i;
  assign access_set = (SETS == 1) ? '0 : icache_set_index_t'(access_addr_i >> ICACHE_LINE_OFFSET_W);
  assign access_line = access_addr_i[PADDR_WIDTH-1:ICACHE_LINE_OFFSET_W];
  always_comb begin
    access_way = allocate_way_i;
    if (hit_i) begin
      for (int way = 0; way < WAYS; way++) begin
        if (hit_way_vector_i[way])
          access_way = icache_way_index_t'(way);
      end
    end
  end

  generate
    if ((POLICY == 4 || POLICY == 5) && WAYS == 2) begin : g_two_way_lru
      logic victim_array_q[SETS];
      logic victim_array_d[SETS];
      always_comb begin
        for (int set_index = 0; set_index < SETS; set_index++) begin
          victim_array_d[set_index] = victim_array_q[set_index];
          if (access_event && access_set == icache_set_index_t'(set_index))
            victim_array_d[set_index] = !access_way[0];
        end
      end
      always_ff @(posedge clk_i) begin
        if (read_enable_i)
          read_victim_o <= icache_way_index_t'(victim_array_d[read_set_i]);
        for (int set_index = 0; set_index < SETS; set_index++) begin
          if (!rst_ni || invalidate_i)
            victim_array_q[set_index] <= 1'b0;
          else
            victim_array_q[set_index] <= victim_array_d[set_index];
        end
      end
    end else if (POLICY == 4) begin : g_lru
      logic [WAY_BITS-1:0] age_array_q[SETS][WAYS];
      logic [WAY_BITS-1:0] age_array_d[SETS][WAYS];
      icache_way_index_t read_victim;

      always_comb begin
        for (int set_index = 0; set_index < SETS; set_index++) begin
          for (int way = 0; way < WAYS; way++) begin
            age_array_d[set_index][way] = age_array_q[set_index][way];
            if (access_event && access_set == icache_set_index_t'(set_index)) begin
              if (access_way == icache_way_index_t'(way))
                age_array_d[set_index][way] = '0;
              else if (age_array_q[set_index][way] < age_array_q[set_index][access_way])
                age_array_d[set_index][way] = age_array_q[set_index][way] + 1'b1;
            end
          end
        end
        read_victim = '0;
        for (int way = 1; way < WAYS; way++) begin
          if (age_array_d[read_set_i][way] > age_array_d[read_set_i][read_victim])
            read_victim = icache_way_index_t'(way);
        end
      end
      always_ff @(posedge clk_i) begin
        if (read_enable_i)
          read_victim_o <= read_victim;
        for (int set_index = 0; set_index < SETS; set_index++) begin
          for (int way = 0; way < WAYS; way++) begin
            if (!rst_ni || invalidate_i)
              age_array_q[set_index][way] <= WAY_BITS'(WAYS - 1);
            else
              age_array_q[set_index][way] <= age_array_d[set_index][way];
          end
        end
      end
    end else if (POLICY == 5) begin : g_plru
      logic [WAYS-2:0] tree_array_q[SETS];
      logic [WAYS-2:0] tree_array_d[SETS];
      icache_way_index_t read_victim;
      integer update_node, read_node;
      logic direction;

      always_comb begin
        for (int set_index = 0; set_index < SETS; set_index++)
          tree_array_d[set_index] = tree_array_q[set_index];
        update_node = 0;
        for (int depth = 0; depth < WAY_BITS; depth++) begin
          if (access_event)
            tree_array_d[access_set][update_node] = !access_way[WAY_BITS-1-depth];
          update_node = 2 * update_node + 1 + int'(access_way[WAY_BITS-1-depth]);
        end
        read_node   = 0;
        read_victim = '0;
        direction   = 1'b0;
        for (int depth = 0; depth < WAY_BITS; depth++) begin
          direction = tree_array_d[read_set_i][read_node];
          read_victim[WAY_BITS-1-depth] = direction;
          read_node = 2 * read_node + 1 + int'(direction);
        end
      end
      always_ff @(posedge clk_i) begin
        if (read_enable_i)
          read_victim_o <= read_victim;
        for (int set_index = 0; set_index < SETS; set_index++) begin
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
      localparam bit BURST = (POLICY >= 9 && POLICY <= 11) || POLICY == 13 || POLICY >= 15;
      localparam bit LEARNED = POLICY == 10 || POLICY == 11 || POLICY >= 15;
      localparam bit PATH_HISTORY = POLICY == 11 || POLICY == 15;
      localparam bit QUERY_BYPASS = POLICY >= 13;
      localparam int unsigned LEADER_STRIDE = (SETS >= 32) ? 32 : ((SETS >= 4) ? SETS : 4);
      logic [1:0] rrpv_array_q[SETS][WAYS], rrpv_array_d[SETS][WAYS];
      logic [4:0] insertion_count_q, insertion_count_d;
      logic [9:0] selector_q, selector_d;
      logic [LINE_ADDR_BITS-1:0] previous_line_q;
      logic previous_line_present_q;
      logic [15:0] history_q;
      logic [5:0] signature_array_q[SETS][WAYS], signature_array_d[SETS][WAYS];
      logic reused_array_q[SETS][WAYS], reused_array_d[SETS][WAYS];
      logic [1:0] prediction_array_q[64], prediction_array_d[64];
      logic burst_start, bimodal;
      logic [5:0] signature;
      logic [1:0] maximum_rrpv, age_amount, insertion;
      logic [1:0] read_rrpv_array [WAYS];
      icache_way_index_t read_victim;

      // 当前行地址发生变化时，开始新的访问段。
      assign burst_start = !previous_line_present_q || previous_line_q != access_line;
      assign signature = 6'(access_line ^ (access_line >> 6)) ^ (PATH_HISTORY ? history_q[5:0] : 6'd0);

      // 先训练旧身份，再查新签名，覆盖同索引训练/插入的旁路。每拍最多一次训练。
      always_comb begin
        for (int index = 0; index < 64; index++)
          prediction_array_d[index] = prediction_array_q[index];
        for (int set_index = 0; set_index < SETS; set_index++) begin
          for (int way = 0; way < WAYS; way++) begin
            signature_array_d[set_index][way] = signature_array_q[set_index][way];
            reused_array_d[set_index][way] = reused_array_q[set_index][way];
          end
        end
        if (LEARNED && allocate_i) begin
          if (victim_present_i && !reused_array_q[access_set][access_way] &&
              prediction_array_q[signature_array_q[access_set][access_way]] != 0)
            prediction_array_d[signature_array_q[access_set][access_way]] =
                prediction_array_q[signature_array_q[access_set][access_way]] - 1'b1;
          signature_array_d[access_set][access_way] = signature;
          reused_array_d[access_set][access_way] = 1'b0;
        end else if (LEARNED && hit_i && burst_start && !reused_array_q[access_set][access_way]) begin
          if (prediction_array_q[signature_array_q[access_set][access_way]] != 3)
            prediction_array_d[signature_array_q[access_set][access_way]] =
                prediction_array_q[signature_array_q[access_set][access_way]] + 1'b1;
          reused_array_d[access_set][access_way] = 1'b1;
        end
      end

      always_comb begin
        insertion_count_d = insertion_count_q;
        selector_d = selector_q;
        bimodal = POLICY == 7;
        if (allocate_i)
          insertion_count_d = insertion_count_q + 1'b1;
        if (POLICY == 8) begin
          if (int'(access_set) % LEADER_STRIDE == 0) begin
            if (allocate_i && selector_q != 1023)
              selector_d = selector_q + 1'b1;
            bimodal = 1'b0;
          end else if (int'(access_set) % LEADER_STRIDE == LEADER_STRIDE - 1) begin
            if (allocate_i && selector_q != 0)
              selector_d = selector_q - 1'b1;
            bimodal = 1'b1;
          end else
            bimodal = selector_q >= 512;
        end
        insertion = (bimodal && insertion_count_d != 0) ? 2'd3 : 2'd2;
        if (LEARNED)
          insertion = prediction_array_d[signature] == 0 ? 2'd3 : 2'd2;
        maximum_rrpv = rrpv_array_q[access_set][0];
        for (int way = 1; way < WAYS; way++) begin
          if (rrpv_array_q[access_set][way] > maximum_rrpv)
            maximum_rrpv = rrpv_array_q[access_set][way];
        end
        age_amount = victim_present_i ? 2'd3 - maximum_rrpv : 2'd0;
        for (int set_index = 0; set_index < SETS; set_index++) begin
          for (int way = 0; way < WAYS; way++) begin
            rrpv_array_d[set_index][way] = rrpv_array_q[set_index][way];
            if (access_set == icache_set_index_t'(set_index)) begin
              if (allocate_i) begin
                rrpv_array_d[set_index][way] = rrpv_array_q[set_index][way] + age_amount;
                if (access_way == icache_way_index_t'(way))
                  rrpv_array_d[set_index][way] = insertion;
              end else if (hit_i && access_way == icache_way_index_t'(way) && (!BURST || burst_start))
                rrpv_array_d[set_index][way] = 2'd0;
            end
          end
        end
        // 阻塞式cache的miss分配与新查询互斥；13～16只保留真实的同组hit前递。
        for (int way = 0; way < WAYS; way++) begin
          read_rrpv_array[way] = rrpv_array_d[read_set_i][way];
          if (QUERY_BYPASS) begin
            read_rrpv_array[way] = rrpv_array_q[read_set_i][way];
            if (hit_i && access_set == read_set_i && access_way == icache_way_index_t'(way) &&
                (!BURST || burst_start))
              read_rrpv_array[way] = 2'd0;
          end
        end
        read_victim = '0;
        for (int way = 1; way < WAYS; way++) begin
          if (read_rrpv_array[way] > read_rrpv_array[read_victim])
            read_victim = icache_way_index_t'(way);
        end
      end

      always_ff @(posedge clk_i) begin
        if (read_enable_i)
          read_victim_o <= read_victim;
        if (!rst_ni || invalidate_i) begin
          insertion_count_q <= '0;
          selector_q <= 10'd511;
          previous_line_q <= '0;
          previous_line_present_q <= 1'b0;
          history_q <= '0;
        end else begin
          insertion_count_q <= insertion_count_d;
          selector_q <= selector_d;
          if (access_event) begin
            previous_line_q <= access_line;
            previous_line_present_q <= 1'b1;
            if (burst_start)
              history_q <= (history_q << 3) ^ {13'd0, access_line[2:0]};
          end
        end
        for (int index = 0; index < 64; index++) begin
          if (!rst_ni || invalidate_i)
            prediction_array_q[index] <= 2'd1;
          else
            prediction_array_q[index] <= prediction_array_d[index];
        end
        for (int set_index = 0; set_index < SETS; set_index++) begin
          for (int way = 0; way < WAYS; way++) begin
            if (!rst_ni || invalidate_i) begin
              rrpv_array_q[set_index][way] <= 2'd3;
              signature_array_q[set_index][way] <= '0;
              reused_array_q[set_index][way] <= 1'b0;
            end else begin
              rrpv_array_q[set_index][way] <= rrpv_array_d[set_index][way];
              signature_array_q[set_index][way] <= signature_array_d[set_index][way];
              reused_array_q[set_index][way] <= reused_array_d[set_index][way];
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
