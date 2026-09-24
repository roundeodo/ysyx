// FENCE.I提交后先清理D-cache，再使I-cache失效。清理失败时保留前端阻塞并重新清理；
// 只有一次完整清理成功后才能恢复取指。持续总线错误会持续阻塞，不会执行旧指令数据。
module riscv_cache_maintenance_controller
  import riscv_config_pkg::*;
  import riscv_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,
    input  logic fence_i_committed_i,
    input  logic dcache_clean_done_i,
    input  logic dcache_clean_access_fault_i,
    input  logic icache_invalidate_done_i,
    output logic dcache_clean_req_o,
    output logic icache_invalidate_req_o,
    output logic maintenance_active_o
);
  typedef enum logic [1:0] {
    MAINTENANCE_IDLE,
    CLEAN_DCACHE,
    RETRY_DCACHE,
    INVALIDATE_ICACHE
  } maintenance_state_e;

  maintenance_state_e state_q, state_d;

  // 请求由寄存状态产生，提交事件不进入cache ready组合路径。
  assign maintenance_active_o    = state_q != MAINTENANCE_IDLE;
  assign dcache_clean_req_o      = state_q == CLEAN_DCACHE;
  assign icache_invalidate_req_o = state_q == INVALIDATE_ICACHE;

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      MAINTENANCE_IDLE: begin
        if (fence_i_committed_i) state_d = DCACHE_ENABLED ? CLEAN_DCACHE : INVALIDATE_ICACHE;
      end
      CLEAN_DCACHE: begin
        if (dcache_clean_done_i)
          state_d = dcache_clean_access_fault_i ? RETRY_DCACHE : INVALIDATE_ICACHE;
      end
      // 清理接口通过撤下req结束旧事务，间隔一拍后重新请求。失败行仍为dirty。
      RETRY_DCACHE: state_d = CLEAN_DCACHE;
      INVALIDATE_ICACHE: begin
        if (icache_invalidate_done_i) state_d = MAINTENANCE_IDLE;
      end
      default:      state_d = MAINTENANCE_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= MAINTENANCE_IDLE;
    else state_q <= state_d;
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    dcache_clean_req_o && dcache_clean_done_i && dcache_clean_access_fault_i |=>
      maintenance_active_o && !icache_invalidate_req_o)
  else $error("cache maintenance resumed instruction fetch after a failed writeback");
`endif
endmodule
