// LSU语义访存边界：依据PMA在D-cache与uncached路径之间选择，并合并成一个data AXI manager。
//
// 路由选择在请求握手时锁定到响应完成，不能根据后续地址重新组合选择。cacheable普通
// 内存进入D-cache；MMIO和低延迟片上存储走uncached；未映射或权限不允许的访问本地报错。
module riscv32_data_mem
  import riscv_config_pkg::*;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    input  data_memory_req_t  data_memory_req_i,
    input  logic              data_memory_req_valid_i,
    output logic              data_memory_req_ready_o,
    output data_memory_resp_t data_memory_resp_o,
    output logic              data_memory_resp_valid_o,
    input  logic              data_memory_resp_ready_i,

    input  logic dcache_clean_req_i,
    output logic dcache_clean_done_o,
    output logic dcache_clean_access_fault_o,
    output logic dcache_busy_o,

    output dcache_event_t dcache_event_o,

    output axi4_manager_to_target_t axi_manager_o,
    input  axi4_target_to_manager_t axi_manager_i
);

  typedef enum logic [1:0] {
    DATA_ROUTE_IDLE,
    DATA_ROUTE_DCACHE,
    DATA_ROUTE_UNCACHED,
    DATA_ROUTE_ACCESS_FAULT
  } data_route_state_e;

  data_route_state_e route_state_q, route_state_d;
  data_route_state_e selected_request_route;
  pma_attr_t         request_memory_attr;
  logic              request_access_allowed;
  mem_txn_id_t       fault_transaction_id_q, fault_transaction_id_d;

  data_memory_req_t        dcache_req;
  logic                    dcache_req_valid;
  logic                    dcache_req_ready;
  data_memory_resp_t       dcache_resp;
  logic                    dcache_resp_valid;
  logic                    dcache_resp_ready;
  axi4_manager_to_target_t dcache_axi_manager;
  axi4_target_to_manager_t dcache_axi_response;

  data_memory_req_t        uncached_req;
  logic                    uncached_req_valid;
  logic                    uncached_req_ready;
  data_memory_resp_t       uncached_resp;
  logic                    uncached_resp_valid;
  logic                    uncached_resp_ready;
  axi4_manager_to_target_t uncached_axi_manager;
  axi4_target_to_manager_t uncached_axi_response;

  localparam int unsigned COUNT_W = $clog2(LSU_ENTRIES + 1);
  logic [COUNT_W-1:0] cache_count_q;
  logic cache_request_handshake, cache_response_handshake, last_response;
  logic new_request_window_open;
  logic selected_data_request_ready;
  logic selected_request_handshake;
  logic local_resp_handshake;

  riscv32_pma u_data_pma (
      .lookup_addr_i (data_memory_req_i.addr),
      .memory_attr_o (request_memory_attr)
  );

  always_comb begin
    request_access_allowed = 1'b0;
    unique case (data_memory_req_i.cmd)
      MEM_CMD_LOAD: request_access_allowed = request_memory_attr.readable;
      MEM_CMD_STORE: request_access_allowed = request_memory_attr.writable;
      default: request_access_allowed = 1'b0;
    endcase

    if (!request_access_allowed) begin
      selected_request_route = DATA_ROUTE_ACCESS_FAULT;
    end else if (DCACHE_ENABLED && request_memory_attr.cacheable) begin
      selected_request_route = DATA_ROUTE_DCACHE;
    end else begin
      selected_request_route = DATA_ROUTE_UNCACHED;
    end
  end

  // 多个 cache 请求共享同一路由；最后一个响应交付后才能切换到 MMIO/故障路径。
  assign last_response = local_resp_handshake &&
      (route_state_q != DATA_ROUTE_DCACHE || cache_count_q == 1);
  assign new_request_window_open = (route_state_q == DATA_ROUTE_IDLE) || last_response ||
      ((LSU_ENTRIES > 1) && route_state_q == DATA_ROUTE_DCACHE &&
       selected_request_route == DATA_ROUTE_DCACHE &&
       (int'(cache_count_q) < LSU_ENTRIES || local_resp_handshake));
  assign cache_request_handshake = dcache_req_valid && dcache_req_ready;
  assign cache_response_handshake = dcache_resp_valid && dcache_resp_ready;
  if (LSU_ENTRIES > 1) begin : gen_cache_count
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) cache_count_q <= '0;
      else case ({cache_request_handshake, cache_response_handshake})
        2'b10: cache_count_q <= cache_count_q + 1'b1;
        2'b01: cache_count_q <= cache_count_q - 1'b1;
        default: ;
      endcase
    end
  end else begin : gen_single_route
    // 单请求配置的路由状态已经记录是否占用，不再保存重复计数器。
    assign cache_count_q = COUNT_W'(route_state_q == DATA_ROUTE_DCACHE);
  end

  assign dcache_req   = data_memory_req_i;
  assign uncached_req = data_memory_req_i;

  // IDLE是普通直通窗口；当前响应完成的同一拍也是滚动窗口。
  assign dcache_req_valid = !dcache_clean_req_i &&
      new_request_window_open && data_memory_req_valid_i &&
      selected_request_route == DATA_ROUTE_DCACHE;
  // uncached 不能与 cache 在途请求重叠；无需经过 cache 容量和目标译码的通用窗口。
  // 空闲或最后响应交付时仍当拍直通，ready 与路由更新继续使用统一握手规则。
  assign uncached_req_valid = !dcache_clean_req_i &&
      ((route_state_q == DATA_ROUTE_IDLE) || last_response) && data_memory_req_valid_i &&
      selected_request_route == DATA_ROUTE_UNCACHED;

  always_comb begin
    selected_data_request_ready = 1'b0;
    unique case (selected_request_route)
      DATA_ROUTE_DCACHE:      selected_data_request_ready = dcache_req_ready;
      DATA_ROUTE_UNCACHED:    selected_data_request_ready = uncached_req_ready;
      DATA_ROUTE_ACCESS_FAULT: selected_data_request_ready = 1'b1;
      default: ;
    endcase
  end

  always_comb begin
    data_memory_resp_o       = '0;
    data_memory_resp_valid_o = 1'b0;
    dcache_resp_ready        = 1'b0;
    uncached_resp_ready      = 1'b0;

    unique case (route_state_q)
      DATA_ROUTE_DCACHE: begin
        data_memory_resp_o       = dcache_resp;
        data_memory_resp_valid_o = dcache_resp_valid;
        dcache_resp_ready        = data_memory_resp_ready_i;
      end

      DATA_ROUTE_UNCACHED: begin
        data_memory_resp_o       = uncached_resp;
        data_memory_resp_valid_o = uncached_resp_valid;
        uncached_resp_ready      = data_memory_resp_ready_i;
      end

      DATA_ROUTE_ACCESS_FAULT: begin
        data_memory_resp_o.access_fault   = 1'b1;
        data_memory_resp_o.transaction_id = fault_transaction_id_q;
        data_memory_resp_valid_o          = 1'b1;
      end

      default: ;
    endcase
  end
  assign local_resp_handshake = data_memory_resp_valid_o && data_memory_resp_ready_i;

  // ready由当前PMA路由选中的目标返回。响应完成拍可以同时接收下一请求，避免连续
  // D-cache hit之间出现固定空闲拍；目标反压时由LSU保持请求payload。
  assign data_memory_req_ready_o = !dcache_clean_req_i && new_request_window_open &&
      selected_data_request_ready;
  assign selected_request_handshake = data_memory_req_valid_i && data_memory_req_ready_o;

  // 请求与响应分别选路：交接拍的新 uncached 请求不改变旧响应的归属。
  logic dcache_response_selected;
  assign dcache_response_selected = dcache_clean_req_i || route_state_q == DATA_ROUTE_DCACHE;

  // cache 的总线请求在内部 S1/miss 状态确定，优先选择其实际有效通道。
  // 其余时间预先呈现 uncached payload，不让 LSU 发射允许条件控制宽地址 mux。
  assign axi_manager_o.ar = dcache_axi_manager.ar_valid ?
      dcache_axi_manager.ar : uncached_axi_manager.ar;
  assign axi_manager_o.ar_valid = dcache_axi_manager.ar_valid || uncached_axi_manager.ar_valid;
  assign axi_manager_o.aw = dcache_axi_manager.aw_valid ?
      dcache_axi_manager.aw : uncached_axi_manager.aw;
  assign axi_manager_o.aw_valid = dcache_axi_manager.aw_valid || uncached_axi_manager.aw_valid;
  assign axi_manager_o.w = dcache_axi_manager.w_valid ? dcache_axi_manager.w : uncached_axi_manager.w;
  assign axi_manager_o.w_valid = dcache_axi_manager.w_valid || uncached_axi_manager.w_valid;
  assign axi_manager_o.r_ready = dcache_response_selected ?
      dcache_axi_manager.r_ready : uncached_axi_manager.r_ready;
  assign axi_manager_o.b_ready = dcache_response_selected ?
      dcache_axi_manager.b_ready : uncached_axi_manager.b_ready;

  assign dcache_axi_response.ar_ready = axi_manager_i.ar_ready;
  assign dcache_axi_response.aw_ready = axi_manager_i.aw_ready;
  assign dcache_axi_response.w_ready = axi_manager_i.w_ready;
  assign dcache_axi_response.r = axi_manager_i.r;
  assign dcache_axi_response.r_valid = dcache_response_selected && axi_manager_i.r_valid;
  assign dcache_axi_response.b = axi_manager_i.b;
  assign dcache_axi_response.b_valid = dcache_response_selected && axi_manager_i.b_valid;
  assign uncached_axi_response.ar_ready = !dcache_axi_manager.ar_valid && axi_manager_i.ar_ready;
  assign uncached_axi_response.aw_ready = !dcache_axi_manager.aw_valid && axi_manager_i.aw_ready;
  assign uncached_axi_response.w_ready = !dcache_axi_manager.w_valid && axi_manager_i.w_ready;
  assign uncached_axi_response.r = axi_manager_i.r;
  assign uncached_axi_response.r_valid = !dcache_response_selected && axi_manager_i.r_valid;
  assign uncached_axi_response.b = axi_manager_i.b;
  assign uncached_axi_response.b_valid = !dcache_response_selected && axi_manager_i.b_valid;

  always_comb begin
    route_state_d          = route_state_q;
    fault_transaction_id_d = fault_transaction_id_q;
    if (selected_request_handshake) begin
      route_state_d = selected_request_route;
      if (selected_request_route == DATA_ROUTE_ACCESS_FAULT) begin
        fault_transaction_id_d = data_memory_req_i.transaction_id;
      end
    end else if (route_state_q != DATA_ROUTE_IDLE && last_response) begin
      route_state_d = DATA_ROUTE_IDLE;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      route_state_q <= DATA_ROUTE_IDLE;
    else
      route_state_q <= route_state_d;
  end

  always_ff @(posedge clk_i) begin
    fault_transaction_id_q <= fault_transaction_id_d;
  end

  generate
    if (DCACHE_ENABLED) begin : gen_dcache
      riscv32_dcache u_dcache (
          .clk_i                    (clk_i),
          .rst_ni                   (rst_ni),
          .data_memory_req_i        (dcache_req),
          .data_memory_req_valid_i  (dcache_req_valid),
          .data_memory_req_ready_o  (dcache_req_ready),
          .data_memory_resp_o       (dcache_resp),
          .data_memory_resp_valid_o (dcache_resp_valid),
          .data_memory_resp_ready_i (dcache_resp_ready),
          .clean_req_i              (dcache_clean_req_i),
          .clean_done_o             (dcache_clean_done_o),
          .clean_access_fault_o     (dcache_clean_access_fault_o),
          .cache_busy_o             (dcache_busy_o),
          .event_o                  (dcache_event_o),
          .axi_manager_o            (dcache_axi_manager),
          .axi_manager_i            (dcache_axi_response)
      );
    end else begin : gen_no_dcache
      assign dcache_req_ready            = 1'b0;
      assign dcache_resp                 = '0;
      assign dcache_resp_valid           = 1'b0;
      assign dcache_clean_done_o         = dcache_clean_req_i;
      assign dcache_clean_access_fault_o = 1'b0;
      assign dcache_busy_o               = 1'b0;
      assign dcache_event_o              = '0;
      assign dcache_axi_manager          = '0;
    end
  endgenerate

  riscv32_uncached_axi u_uncached_axi (
      .clk_i                    (clk_i),
      .rst_ni                   (rst_ni),
      .data_memory_req_i        (uncached_req),
      .data_memory_req_valid_i  (uncached_req_valid),
      .data_memory_req_ready_o  (uncached_req_ready),
      .data_memory_resp_o       (uncached_resp),
      .data_memory_resp_valid_o (uncached_resp_valid),
      .data_memory_resp_ready_i (uncached_resp_ready),
      .axi_manager_o            (uncached_axi_manager),
      .axi_manager_i            (uncached_axi_response)
  );

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni) int'(cache_count_q) <= LSU_ENTRIES);
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    cache_response_handshake |-> cache_count_q != 0);

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    !((dcache_axi_manager.ar_valid && uncached_axi_manager.ar_valid) ||
      (dcache_axi_manager.aw_valid && uncached_axi_manager.aw_valid) ||
      (dcache_axi_manager.w_valid && uncached_axi_manager.w_valid)))
  else $error("D-cache and uncached requests competed on one AXI channel");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    dcache_clean_req_i |-> route_state_q == DATA_ROUTE_IDLE)
  else
    $error("D-cache clean started while an LSU memory transaction was active");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    data_memory_req_valid_i && !data_memory_req_ready_o |=>
      (data_memory_req_valid_i && $stable(data_memory_req_i)))
  else
    $error("data memory request changed while the subsystem was stalled");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    route_state_q != DATA_ROUTE_IDLE && local_resp_handshake &&
      data_memory_req_valid_i && !data_memory_req_ready_o |=> data_memory_req_valid_i)
  else
    $error("LSU did not retain a rollover request rejected by the memory target");

`endif

endmodule
