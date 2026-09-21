// FENCE.I 提交后依次排空取指、写回 D-cache、失效 I-cache。
// 唯一状态为维护状态机和一个请求保持位；不增加指令流水级。
module riscv32_fence_i_ctrl
  import riscv_config_pkg::*;
  import riscv32_pkg::*;
(
    input  logic          clk_i,
    input  logic          rst_ni,
    input  logic          commit_valid_i,
    input  commit_t       commit_i,
    input  logic          icache_lookup_req_valid_i,
    input  logic          icache_lookup_req_ready_i,
    input  logic          icache_busy_i,
    input  logic          dcache_clean_done_i,
    input  logic          dcache_clean_access_fault_i,
    input  logic          icache_invalidate_done_i,
    output logic          committed_fence_i_event_o,
    output redirect_req_t fence_i_redirect_req_o,
    output logic          fence_i_maintenance_active_o,
    output logic          frontend_memory_access_allowed_o,
    output logic          frontend_prediction_allowed_o,
    output logic          maintenance_failed_o,
    output logic          dcache_clean_req_o,
    output logic          icache_invalidate_req_o
);
  typedef enum logic [2:0] {
    FENCE_I_MAINTENANCE_IDLE,
    FENCE_I_DRAIN_FRONTEND,
    FENCE_I_CLEAN_DCACHE,
    FENCE_I_INVALIDATE_ICACHE,
    FENCE_I_FAILED
  } fence_i_maintenance_state_e;

  fence_i_maintenance_state_e fence_i_maintenance_state_q;
  fence_i_maintenance_state_e fence_i_maintenance_state_d;

  logic icache_lookup_stalled_q;

  assign committed_fence_i_event_o =
      commit_valid_i && !commit_i.trap_taken && (commit_i.system_op == SYS_FENCE_I);
  assign fence_i_maintenance_active_o   = fence_i_maintenance_state_q != FENCE_I_MAINTENANCE_IDLE;
  assign frontend_prediction_allowed_o = !fence_i_maintenance_active_o && !committed_fence_i_event_o;
  assign maintenance_failed_o           = fence_i_maintenance_state_q == FENCE_I_FAILED;
  // 维护期间暂停新请求，但已经拉高 valid 的请求必须保持到握手。
  assign frontend_memory_access_allowed_o = !fence_i_maintenance_active_o || icache_lookup_stalled_q;
  assign dcache_clean_req_o               = fence_i_maintenance_state_q == FENCE_I_CLEAN_DCACHE;
  assign icache_invalidate_req_o          = fence_i_maintenance_state_q == FENCE_I_INVALIDATE_ICACHE;

  always_comb begin
    fence_i_redirect_req_o                 = '0;
    fence_i_redirect_req_o.target_pc       = commit_i.next_pc;
    fence_i_redirect_req_o.source_pc       = commit_i.pc;
    fence_i_redirect_req_o.reason          = REDIRECT_FENCE_I;
    fence_i_redirect_req_o.flush_inclusive = 1'b0;
  end

  always_comb begin
    fence_i_maintenance_state_d = fence_i_maintenance_state_q;
    unique case (fence_i_maintenance_state_q)
      FENCE_I_MAINTENANCE_IDLE: begin
        if (committed_fence_i_event_o) begin
          fence_i_maintenance_state_d = FENCE_I_DRAIN_FRONTEND;
        end
      end
      FENCE_I_DRAIN_FRONTEND: begin
        if (!icache_lookup_stalled_q && !icache_busy_i) begin
          fence_i_maintenance_state_d = DCACHE_ENABLED ? FENCE_I_CLEAN_DCACHE :
              FENCE_I_INVALIDATE_ICACHE;
        end
      end
      FENCE_I_CLEAN_DCACHE: begin
        if (dcache_clean_done_i) begin
          fence_i_maintenance_state_d = dcache_clean_access_fault_i ?
              FENCE_I_FAILED : FENCE_I_INVALIDATE_ICACHE;
        end
      end
      FENCE_I_INVALIDATE_ICACHE: begin
        if (icache_invalidate_done_i) begin
          fence_i_maintenance_state_d = FENCE_I_MAINTENANCE_IDLE;
        end
      end
      // 已退休 FENCE.I 的维护失败不能伪造精确异常；保持停机，等待系统复位。
      FENCE_I_FAILED: ;
      default: fence_i_maintenance_state_d = FENCE_I_FAILED;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      icache_lookup_stalled_q <= 1'b0;
    end else begin
      icache_lookup_stalled_q <= icache_lookup_req_valid_i && frontend_memory_access_allowed_o &&
          !icache_lookup_req_ready_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fence_i_maintenance_state_q <= FENCE_I_MAINTENANCE_IDLE;
    end else begin
      fence_i_maintenance_state_q <= fence_i_maintenance_state_d;
    end
  end
endmodule
