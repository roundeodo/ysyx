// 单manager、多target的完整AXI4地址路由器。
// 读写事务可并行进行；每个方向各允许一个事务在途。
module riscv32_axi4_router
  import riscv32_axi4_pkg::*;
#(
    parameter int unsigned TARGET_COUNT = 2,
    // 路由地址数组与AXI fabric共用地址宽度，不建立路由器局部宽度配置。
    parameter logic [MEM_AXI_ADDR_WIDTH-1:0] TARGET_ADDRESS_BASE_ARRAY[TARGET_COUNT] =
        '{default: '0},
    parameter logic [MEM_AXI_ADDR_WIDTH-1:0] TARGET_ADDRESS_LAST_ARRAY[TARGET_COUNT] =
        '{default: '1},
    parameter logic TARGET_ADDRESS_SELECT_ENABLE_ARRAY[TARGET_COUNT] =
        '{default: 1'b1},
    parameter bit DEFAULT_TARGET_ENABLE = 1'b0,
    parameter int unsigned DEFAULT_TARGET_INDEX = 0
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  axi4_manager_to_target_t upstream_manager_i,
    output axi4_target_to_manager_t upstream_manager_o,

    output axi4_manager_to_target_t target_manager_array_o[TARGET_COUNT],
    input  axi4_target_to_manager_t target_manager_array_i[TARGET_COUNT]
);

  localparam int unsigned TARGET_INDEX_WIDTH =
      (TARGET_COUNT <= 1) ? 1 : $clog2(TARGET_COUNT);

  typedef logic [TARGET_INDEX_WIDTH-1:0] target_index_t;

  typedef enum logic {
    READ_ROUTE_ADDRESS,
    READ_FORWARD_DATA
  } read_route_state_e;

  typedef enum logic [1:0] {
    WRITE_ROUTE_ADDRESS,
    WRITE_FORWARD_DATA,
    WRITE_FORWARD_RESPONSE
  } write_route_state_e;

  read_route_state_e  read_state_q;
  read_route_state_e  read_state_d;
  write_route_state_e write_state_q;
  write_route_state_e write_state_d;

  target_index_t selected_read_target_index_q;
  target_index_t selected_read_target_index_d;
  target_index_t selected_write_target_index_q;
  target_index_t selected_write_target_index_d;

  // AW尚未完成时，W允许同拍直通。该位只记录这一事务的WLAST是否已经握手，
  // 不缓存W payload，也不改变AXI4五通道的独立语义。
  logic write_last_data_occurred_q;
  logic write_last_data_occurred_d;

  logic [TARGET_COUNT-1:0] read_target_select_vector;
  logic [TARGET_COUNT-1:0] write_target_select_vector;
  logic                    read_target_selection_present;
  logic                    write_target_selection_present;
  target_index_t           read_target_select_index;
  target_index_t           write_target_select_index;

  logic upstream_read_address_handshake;
  logic upstream_read_data_handshake;
  logic upstream_write_address_handshake;
  logic upstream_write_data_handshake;
  logic upstream_write_response_handshake;

  logic read_address_window;
  logic write_address_window;
  logic write_last_already_accepted;
  assign read_address_window = (read_state_q == READ_ROUTE_ADDRESS) ||
      (upstream_read_data_handshake && upstream_manager_o.r.last);
  assign write_address_window = (write_state_q == WRITE_ROUTE_ADDRESS) ||
      upstream_write_response_handshake;
  assign write_last_already_accepted =
      (write_state_q == WRITE_ROUTE_ADDRESS) && write_last_data_occurred_q;

  function automatic target_index_t select_index_from_vector(
      input  logic [TARGET_COUNT-1:0] target_select_vector
  );
    target_index_t selected_index;
    selected_index = '0;
    for (int unsigned target = 0; target < TARGET_COUNT; target++) begin
      if (target_select_vector[target]) begin
        selected_index = target_index_t'(target);
      end
    end
    return selected_index;
  endfunction

  // 地址选择结果是“每个target是否被当前地址选中”的向量。default target应连接
  // error target或系统外部端口，路由器本身不伪造总线响应。
  always_comb begin
    read_target_select_vector  = '0;
    write_target_select_vector = '0;

    for (int unsigned target = 0; target < TARGET_COUNT; target++) begin
      if (TARGET_ADDRESS_SELECT_ENABLE_ARRAY[target] &&
          upstream_manager_i.ar.addr >= TARGET_ADDRESS_BASE_ARRAY[target] &&
          upstream_manager_i.ar.addr <= TARGET_ADDRESS_LAST_ARRAY[target]) begin
        read_target_select_vector[target] = 1'b1;
      end

      if (TARGET_ADDRESS_SELECT_ENABLE_ARRAY[target] &&
          upstream_manager_i.aw.addr >= TARGET_ADDRESS_BASE_ARRAY[target] &&
          upstream_manager_i.aw.addr <= TARGET_ADDRESS_LAST_ARRAY[target]) begin
        write_target_select_vector[target] = 1'b1;
      end
    end

    if (DEFAULT_TARGET_ENABLE && !(|read_target_select_vector)) begin
      read_target_select_vector[DEFAULT_TARGET_INDEX] = 1'b1;
    end
    if (DEFAULT_TARGET_ENABLE && !(|write_target_select_vector)) begin
      write_target_select_vector[DEFAULT_TARGET_INDEX] = 1'b1;
    end
  end

  assign read_target_selection_present  = |read_target_select_vector;
  assign write_target_selection_present = |write_target_select_vector;
  assign read_target_select_index       = select_index_from_vector(read_target_select_vector);
  assign write_target_select_index      = select_index_from_vector(write_target_select_vector);

  assign upstream_read_address_handshake =
      upstream_manager_i.ar_valid && upstream_manager_o.ar_ready;
  assign upstream_read_data_handshake =
      upstream_manager_o.r_valid && upstream_manager_i.r_ready;
  assign upstream_write_address_handshake =
      upstream_manager_i.aw_valid && upstream_manager_o.aw_ready;
  assign upstream_write_data_handshake =
      upstream_manager_i.w_valid && upstream_manager_o.w_ready;
  assign upstream_write_response_handshake =
      upstream_manager_o.b_valid && upstream_manager_i.b_ready;

  // 五个通道分别驱动：新地址选择不能成为旧响应或 RREADY 的组合依赖。
  for (genvar target = 0; target < TARGET_COUNT; target++) begin : gen_target_channels
    assign target_manager_array_o[target].ar = upstream_manager_i.ar;
    assign target_manager_array_o[target].ar_valid = read_address_window &&
        read_target_selection_present && read_target_select_index == target_index_t'(target) &&
        upstream_manager_i.ar_valid;
    assign target_manager_array_o[target].r_ready = (read_state_q == READ_FORWARD_DATA) &&
        selected_read_target_index_q == target_index_t'(target) && upstream_manager_i.r_ready;
    assign target_manager_array_o[target].aw = upstream_manager_i.aw;
    assign target_manager_array_o[target].aw_valid = write_address_window &&
        write_target_selection_present && write_target_select_index == target_index_t'(target) &&
        upstream_manager_i.aw_valid;
    assign target_manager_array_o[target].w = upstream_manager_i.w;
    assign target_manager_array_o[target].w_valid = upstream_manager_i.w_valid &&
        ((write_address_window && write_target_selection_present && upstream_manager_i.aw_valid &&
          !write_last_already_accepted && write_target_select_index == target_index_t'(target)) ||
         ((write_state_q == WRITE_FORWARD_DATA) &&
          selected_write_target_index_q == target_index_t'(target)));
    assign target_manager_array_o[target].b_ready = (write_state_q == WRITE_FORWARD_RESPONSE) &&
        selected_write_target_index_q == target_index_t'(target) && upstream_manager_i.b_ready;
  end

  assign upstream_manager_o.ar_ready = read_address_window && read_target_selection_present &&
      target_manager_array_i[read_target_select_index].ar_ready;
  assign upstream_manager_o.r = target_manager_array_i[selected_read_target_index_q].r;
  assign upstream_manager_o.r_valid = (read_state_q == READ_FORWARD_DATA) &&
      target_manager_array_i[selected_read_target_index_q].r_valid;
  assign upstream_manager_o.aw_ready = write_address_window && write_target_selection_present &&
      target_manager_array_i[write_target_select_index].aw_ready;
  assign upstream_manager_o.w_ready = write_address_window ?
      (write_target_selection_present && upstream_manager_i.aw_valid && !write_last_already_accepted &&
       target_manager_array_i[write_target_select_index].w_ready) :
      ((write_state_q == WRITE_FORWARD_DATA) && target_manager_array_i[selected_write_target_index_q].w_ready);
  assign upstream_manager_o.b = target_manager_array_i[selected_write_target_index_q].b;
  assign upstream_manager_o.b_valid = (write_state_q == WRITE_FORWARD_RESPONSE) &&
      target_manager_array_i[selected_write_target_index_q].b_valid;

  // 第二段：状态转换。选择索引在请求地址握手后锁定，直到最后一个响应完成。
  always_comb begin
    read_state_d                 = read_state_q;
    selected_read_target_index_d = selected_read_target_index_q;

    if (upstream_read_data_handshake && upstream_manager_o.r.last)
      read_state_d = READ_ROUTE_ADDRESS;
    if (upstream_read_address_handshake) begin
      selected_read_target_index_d = read_target_select_index;
      read_state_d = READ_FORWARD_DATA;
    end
  end

  always_comb begin
    write_state_d = write_state_q;
    selected_write_target_index_d = selected_write_target_index_q;
    write_last_data_occurred_d = write_last_data_occurred_q;
    if (upstream_write_response_handshake) begin
      write_last_data_occurred_d = 1'b0;
      write_state_d = WRITE_ROUTE_ADDRESS;
    end
    if (write_address_window) begin
      if (upstream_write_data_handshake && upstream_manager_i.w.last)
        write_last_data_occurred_d = 1'b1;
      if (upstream_write_address_handshake) begin
        selected_write_target_index_d = write_target_select_index;
        write_state_d = (write_last_already_accepted ||
            (upstream_write_data_handshake && upstream_manager_i.w.last)) ?
            WRITE_FORWARD_RESPONSE : WRITE_FORWARD_DATA;
      end
    end else if (write_state_q == WRITE_FORWARD_DATA &&
                 upstream_write_data_handshake && upstream_manager_i.w.last) begin
      write_last_data_occurred_d = 1'b1;
      write_state_d = WRITE_FORWARD_RESPONSE;
    end
  end

  // 第三段：读路由、写路由和写数据进度分别更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_state_q                 <= READ_ROUTE_ADDRESS;
      selected_read_target_index_q <= '0;
    end else begin
      read_state_q                 <= read_state_d;
      selected_read_target_index_q <= selected_read_target_index_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_state_q                 <= WRITE_ROUTE_ADDRESS;
      selected_write_target_index_q <= '0;
    end else begin
      write_state_q                 <= write_state_d;
      selected_write_target_index_q <= selected_write_target_index_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      write_last_data_occurred_q <= 1'b0;
    else
      write_last_data_occurred_q <= write_last_data_occurred_d;
  end

endmodule
