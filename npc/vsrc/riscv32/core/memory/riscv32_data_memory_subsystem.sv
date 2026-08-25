// LSU语义访存边界：依据PMA在D-cache与uncached路径之间选择，并合并成一个data AXI manager。
//
// 路由选择在请求握手时锁定到响应完成，不能根据后续地址重新组合选择。cacheable普通
// 内存进入D-cache；MMIO和低延迟片上存储走uncached；未映射或权限不允许的访问本地报错。
module riscv32_data_memory_subsystem
  import riscv_config_pkg::*;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  data_memory_req_t data_memory_req_i,
    input  logic             data_memory_req_valid_i,
    output logic             data_memory_req_ready_o,
    output data_memory_resp_t data_memory_resp_o,
    output logic              data_memory_resp_valid_o,
    input  logic              data_memory_resp_ready_i,

    input  logic dcache_clean_req_i,
    output logic dcache_clean_done_o,
    output logic dcache_clean_access_fault_o,
    output logic dcache_busy_o,

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
  pma_attr_t request_memory_attr;
  logic request_access_allowed;
  mem_txn_id_t fault_transaction_id_q, fault_transaction_id_d;

  data_memory_req_t dcache_req;
  logic dcache_req_valid;
  logic dcache_req_ready;
  data_memory_resp_t dcache_resp;
  logic dcache_resp_valid;
  logic dcache_resp_ready;
  axi4_manager_to_target_t dcache_axi_manager;
  axi4_target_to_manager_t dcache_axi_response;

  data_memory_req_t uncached_req;
  logic uncached_req_valid;
  logic uncached_req_ready;
  data_memory_resp_t uncached_resp;
  logic uncached_resp_valid;
  logic uncached_resp_ready;
  axi4_manager_to_target_t uncached_axi_manager;
  axi4_target_to_manager_t uncached_axi_response;

  logic local_req_handshake;
  logic local_resp_handshake;

  riscv32_pma u_data_pma (
      .lookup_addr_i(data_memory_req_i.addr),
      .memory_attr_o(request_memory_attr)
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

  assign dcache_req = data_memory_req_i;
  assign uncached_req = data_memory_req_i;
  assign dcache_req_valid = route_state_q == DATA_ROUTE_IDLE &&
                            !dcache_clean_req_i && data_memory_req_valid_i &&
                            selected_request_route == DATA_ROUTE_DCACHE;
  assign uncached_req_valid = route_state_q == DATA_ROUTE_IDLE &&
                              !dcache_clean_req_i && data_memory_req_valid_i &&
                              selected_request_route == DATA_ROUTE_UNCACHED;

  always_comb begin
    data_memory_req_ready_o = 1'b0;
    if (route_state_q == DATA_ROUTE_IDLE && !dcache_clean_req_i) begin
      unique case (selected_request_route)
        DATA_ROUTE_DCACHE: data_memory_req_ready_o = dcache_req_ready;
        DATA_ROUTE_UNCACHED: data_memory_req_ready_o = uncached_req_ready;
        DATA_ROUTE_ACCESS_FAULT: data_memory_req_ready_o = 1'b1;
        default: ;
      endcase
    end
  end
  assign local_req_handshake = data_memory_req_valid_i && data_memory_req_ready_o;

  always_comb begin
    data_memory_resp_o = '0;
    data_memory_resp_valid_o = 1'b0;
    dcache_resp_ready = 1'b0;
    uncached_resp_ready = 1'b0;

    unique case (route_state_q)
      DATA_ROUTE_DCACHE: begin
        data_memory_resp_o = dcache_resp;
        data_memory_resp_valid_o = dcache_resp_valid;
        dcache_resp_ready = data_memory_resp_ready_i;
      end

      DATA_ROUTE_UNCACHED: begin
        data_memory_resp_o = uncached_resp;
        data_memory_resp_valid_o = uncached_resp_valid;
        uncached_resp_ready = data_memory_resp_ready_i;
      end

      DATA_ROUTE_ACCESS_FAULT: begin
        data_memory_resp_o.access_fault = 1'b1;
        data_memory_resp_o.transaction_id = fault_transaction_id_q;
        data_memory_resp_valid_o = 1'b1;
      end

      default: ;
    endcase
  end
  assign local_resp_handshake = data_memory_resp_valid_o && data_memory_resp_ready_i;

  always_comb begin
    route_state_d = route_state_q;
    fault_transaction_id_d = fault_transaction_id_q;
    if (route_state_q == DATA_ROUTE_IDLE && local_req_handshake) begin
      route_state_d = selected_request_route;
      if (selected_request_route == DATA_ROUTE_ACCESS_FAULT) begin
        fault_transaction_id_d = data_memory_req_i.transaction_id;
      end
    end else if (route_state_q != DATA_ROUTE_IDLE && local_resp_handshake) begin
      route_state_d = DATA_ROUTE_IDLE;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) route_state_q <= DATA_ROUTE_IDLE;
    else route_state_q <= route_state_d;
  end

  always_ff @(posedge clk_i) begin
    fault_transaction_id_q <= fault_transaction_id_d;
  end

  generate
    if (DCACHE_ENABLED) begin : gen_dcache
      riscv32_dcache u_dcache (
          .clk_i                       (clk_i),
          .rst_ni                      (rst_ni),
          .data_memory_req_i           (dcache_req),
          .data_memory_req_valid_i     (dcache_req_valid),
          .data_memory_req_ready_o     (dcache_req_ready),
          .data_memory_resp_o          (dcache_resp),
          .data_memory_resp_valid_o    (dcache_resp_valid),
          .data_memory_resp_ready_i    (dcache_resp_ready),
          .clean_req_i                 (dcache_clean_req_i),
          .clean_done_o                (dcache_clean_done_o),
          .clean_access_fault_o        (dcache_clean_access_fault_o),
          .cache_busy_o                (dcache_busy_o),
          .axi_manager_o               (dcache_axi_manager),
          .axi_manager_i               (dcache_axi_response)
      );
    end else begin : gen_no_dcache
      assign dcache_req_ready            = 1'b0;
      assign dcache_resp                 = '0;
      assign dcache_resp_valid           = 1'b0;
      assign dcache_clean_done_o         = dcache_clean_req_i;
      assign dcache_clean_access_fault_o = 1'b0;
      assign dcache_busy_o               = 1'b0;
      assign dcache_axi_manager          = '0;
    end
  endgenerate

  riscv32_uncached_axi4_master u_uncached_axi4_master (
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

  // clean写回在没有LSU事务时也会使用D-cache AXI端口，因此不能只按route_state选择。
  // 普通事务只使用请求握手后锁存的route_state选择AXI来源。D-cache首拍仅启动array
  // lookup，uncached adapter首拍仅锁存请求，两者都不会在IDLE首拍发出有效AXI请求；
  // 因此不能用当前请求的PMA结果组合选择AXI输出，否则会重新形成EX -> LSU -> PMA ->
  // data AXI output的长路径。
  always_comb begin
    axi_manager_o = '0;
    dcache_axi_response = '0;
    uncached_axi_response = '0;

    if (dcache_clean_req_i || route_state_q == DATA_ROUTE_DCACHE) begin
      axi_manager_o = dcache_axi_manager;
      dcache_axi_response = axi_manager_i;
    end else begin
      axi_manager_o = uncached_axi_manager;
      uncached_axi_response = axi_manager_i;
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    dcache_clean_req_i |-> route_state_q == DATA_ROUTE_IDLE)
  else $error("D-cache clean started while an LSU memory transaction was active");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    data_memory_req_valid_i && !data_memory_req_ready_o |=>
      (data_memory_req_valid_i && $stable(data_memory_req_i)))
  else $error("data memory request changed while the subsystem was stalled");
`endif

endmodule
