// Passive observation of the unchanged core; counters never feed DUT control.
module exploration_core_tb;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  axi4_manager_to_target_t instruction_request, data_request, memory_request;
  axi4_target_to_manager_t instruction_response, data_response, memory_response;
  logic result_valid;
  logic [31:0] result;
  riscv32_core #(.RESET_PC(32'h80000000)) dut (
      .clk_i(clk), .rst_ni(rst_n), .timer_interrupt_i(1'b0),
      .instruction_axi4_manager_o(instruction_request), .instruction_axi4_manager_i(instruction_response),
      .data_axi4_manager_o(data_request), .data_axi4_manager_i(data_response));
  riscv32_axi4_arbiter u_arbiter (
      .clk_i(clk), .rst_ni(rst_n),
      .instruction_manager_i(instruction_request), .instruction_manager_o(instruction_response),
      .data_manager_i(data_request), .data_manager_o(data_response),
      .downstream_manager_o(memory_request), .downstream_manager_i(memory_response));
  exploration_axi_memory u_memory (
      .clk_i(clk), .rst_ni(rst_n), .request_i(memory_request), .response_o(memory_response),
      .result_valid_o(result_valid), .result_o(result));

  int cycle = 0, begin_cycle = 0, end_cycle = 0, retired = 0, all_retired = 0;
  int retired_cycles = 0, data_wait = 0, frontend_wait = 0, other_wait = 0;
  int lookups = 0, misses = 0, i_bursts = 0, i_beats = 0, d_beats = 0, d_wait = 0;
  int branch_events = 0, direction_errors = 0, target_errors = 0, indirect_errors = 0;
  int return_errors = 0, nonbranch_errors = 0, lookup_queries = 0, idle_bus = 0;
  int observer = 1, trace_fd = 0, fetch_fd = 0;
  int btb_miss_errors = 0, bht_direction_errors = 0, btb_target_errors = 0;
  int lead_sum = 0, lead_samples = 0, lead_max = 0, hints_resident = 0, hints_absent = 0;
  int response_query_cycle = 0;
  logic response_target_present = 0;
  typedef struct packed {
    logic [31:0] pc;
    logic target_present;
    int query_cycle;
  } query_record_t;
  query_record_t query_by_tag[FRONTEND_TAG_COUNT];
  query_record_t pending_record, execute_record, result_record;
  query_record_t fetch_records[$];
  logic measuring = 0, finished_window = 0;
  logic [31:0] begin_pc, end_pc, expected, digest = 0;
  string trace_name, fetch_name;
  initial begin
    if (!$value$plusargs("begin_pc=%h", begin_pc) || !$value$plusargs("end_pc=%h", end_pc) ||
        !$value$plusargs("expected=%h", expected)) $fatal(1, "missing workload contract");
    void'($value$plusargs("observer=%d", observer));
    if ($value$plusargs("trace=%s", trace_name)) trace_fd = $fopen(trace_name, "w");
    if ($value$plusargs("fetch_trace=%s", fetch_name)) fetch_fd = $fopen(fetch_name, "w");
    repeat (5) @(negedge clk);
    rst_n = 1;
  end
  always @(posedge clk) if (rst_n) begin
    cycle = cycle + 1;
    // Old response metadata is consumed before a same-cycle new query is saved.
    if (observer && dut.u_ifu.lookup_queue_enqueue_event) begin
      query_by_tag[dut.u_ifu.next_frontend_tag_q].pc = dut.next_pc_predictor_lookup_response_pc;
      query_by_tag[dut.u_ifu.next_frontend_tag_q].target_present = response_target_present;
      query_by_tag[dut.u_ifu.next_frontend_tag_q].query_cycle = response_query_cycle;
    end
    if (observer && dut.next_pc_predictor_lookup_request_valid && dut.next_pc_predictor_lookup_request_ready) begin
      response_target_present = dut.u_branch_predictor.target_present;
      response_query_cycle = cycle;
    end
    if (cycle > 20000000) $fatal(1, "workload timeout");
    if (dut.commit_valid) begin
      all_retired++;
      digest = {digest[26:0],digest[31:27]} ^ dut.commit.pc ^ dut.commit.gpr_wdata;
      if (dut.commit.trap_taken) $fatal(1, "unexpected trap at %h cause %d", dut.commit.pc, dut.commit.trap_cause_code);
      if (measuring) begin
        retired++;
        if (observer && trace_fd) $fdisplay(trace_fd, "%h,%h,%h,%0d", dut.commit.pc, dut.commit.instruction, dut.commit.next_pc, cycle);
      end
    end
    if (measuring && observer) begin
      // Mutually exclusive cycle classes. Events below may overlap these classes.
      if (dut.commit_valid) retired_cycles++;
      else if (dut.lsu_transaction_active) data_wait++;
      else if (!dut.decoded_uop_valid && !dut.structural_hazard_present) frontend_wait++;
      else other_wait++;
      if (dut.u_icache.local_lookup_resp_handshake || dut.u_icache.miss_req_handshake) begin
        lookups++;
        if (dut.u_icache.miss_req_handshake) misses++;
        if (fetch_fd) $fdisplay(fetch_fd, "%d,%h,%d", cycle, dut.u_icache.lookup_s1_q.fetch_addr, dut.u_icache.miss_req_handshake);
      end
      if (instruction_request.ar_valid && instruction_response.ar_ready) i_bursts++;
      if (instruction_response.r_valid && instruction_request.r_ready) i_beats++;
      if ((data_response.r_valid && data_request.r_ready) || (data_request.w_valid && data_response.w_ready)) d_beats++;
      if (data_request.ar_valid && !data_response.ar_ready) d_wait++;
      if (!u_arbiter.read_transaction_present_q && !memory_request.ar_valid) idle_bus++;
      if (dut.next_pc_predictor_lookup_request_valid && dut.next_pc_predictor_lookup_request_ready) lookup_queries++;
      if (dut.icache_lookup_req_valid && dut.icache_lookup_req_ready && dut.frontend_memory_access_allowed) begin
        int lead;
        lead = cycle-query_by_tag[dut.icache_lookup_req.frontend_tag].query_cycle;
        lead_sum += lead; lead_samples++;
        if (lead > lead_max) lead_max = lead;
      end
      if (dut.commit_valid) begin
        bit resident;
        int set_index;
        resident = 0;
        set_index = (dut.commit.pc >> ICACHE_LINE_OFFSET_W) & (ICACHE_SET_COUNT-1);
        for (int way = 0; way < ICACHE_WAY_COUNT; way++)
          if (dut.u_icache.u_riscv32_icache_tag_array.line_present_array_q[way][set_index] &&
              dut.u_icache.u_riscv32_icache_tag_array.tag_array_q[way][set_index] ==
              icache_tag_t'(dut.commit.pc >> (ICACHE_LINE_OFFSET_W+ICACHE_SET_INDEX_BITS))) resident = 1;
        if (resident) hints_resident++; else hints_absent++;
      end
      if (dut.sequential_redirect_valid) nonbranch_errors++;
      if (dut.resolved_execute_result_valid && dut.resolved_execute_result_ready &&
          dut.resolved_execute_result.uop.fu_type == FU_BRANCH && !dut.resolved_execute_result.uop.exception_valid) begin
        branch_events++;
        if (dut.resolved_execute_result.redirect_valid) begin
          if (result_record.pc != dut.resolved_execute_result.uop.pc)
            $fatal(1, "passive prediction identity mismatch");
          if (!result_record.target_present) btb_miss_errors++;
          else if (dut.resolved_execute_result.uop.prediction.predicted_taken !=
                   (dut.resolved_execute_result.next_pc != dut.resolved_execute_result.uop.pc+4)) bht_direction_errors++;
          else btb_target_errors++;
          if (dut.resolved_execute_result.uop.branch_ctrl.op == CF_BRANCH) direction_errors++;
          else begin
            target_errors++;
            if (dut.resolved_execute_result.uop.branch_ctrl.op == CF_JALR) begin
              if (dut.resolved_execute_result.uop.instruction[19:15] == 1) return_errors++;
              else indirect_errors++;
            end
          end
        end
      end
    end
    // frontend_tag is only a short transport tag, not a unique backend identity.
    // Mirror actual handoffs with passive context; never infer age from tag wrap.
    if (observer) begin
      if (dut.exu_result_valid && dut.exu_result_ready) result_record = execute_record;
      if (dut.ifu_fetch_entry_valid && dut.ifu_fetch_entry_ready) begin
        if (pending_record.pc != dut.ifu_fetch_entry.pc) $fatal(1, "observer response pairing");
        fetch_records.push_back(pending_record);
      end
      if (dut.idu_fetch_entry_valid && dut.idu_fetch_entry_ready) begin
        if (fetch_records.size() == 0) $fatal(1, "observer decode queue empty");
        execute_record = fetch_records.pop_front();
        if (execute_record.pc != dut.idu_fetch_entry.pc) $fatal(1, "observer decode pairing");
      end
      if (dut.frontend_recovery_event) fetch_records.delete();
      if (dut.icache_lookup_req_valid && dut.icache_lookup_req_ready && dut.frontend_memory_access_allowed) begin
        pending_record = query_by_tag[dut.icache_lookup_req.frontend_tag];
        if (pending_record.pc != dut.icache_lookup_req.fetch_addr) $fatal(1, "observer request pairing");
      end
    end
    // Half-open window (begin retirement, end retirement], including the final NOP.
    if (dut.commit_valid && dut.commit.pc == end_pc) begin
      measuring = 0; finished_window = 1; end_cycle = cycle;
    end
    if (dut.commit_valid && dut.commit.pc == begin_pc) begin
      measuring = 1; begin_cycle = cycle;
    end
    if (result_valid) begin
      if (!finished_window || result != expected) $fatal(1, "reference mismatch got %h expected %h", result, expected);
      $display("RESULT cycles=%0d retired=%0d total_cycles=%0d all_retired=%0d digest=%h checksum=%h", end_cycle-begin_cycle,retired,cycle,all_retired,digest,result);
      $display("COUNTERS retire=%0d data_wait=%0d frontend_wait=%0d other=%0d lookups=%0d misses=%0d i_bursts=%0d i_beats=%0d d_beats=%0d d_wait=%0d branches=%0d conditional_errors=%0d target_errors=%0d indirect_errors=%0d return_errors=%0d nonbranch_errors=%0d queries=%0d idle_bus=%0d", retired_cycles,data_wait,frontend_wait,other_wait,lookups,misses,i_bursts,i_beats,d_beats,d_wait,branch_events,direction_errors,target_errors,indirect_errors,return_errors,nonbranch_errors,lookup_queries,idle_bus);
      if (observer && retired_cycles+data_wait+frontend_wait+other_wait != end_cycle-begin_cycle)
        $fatal(1, "exclusive cycle classification mismatch");
      $display("DETAIL btb_missing=%0d direction=%0d target=%0d lead_sum=%0d lead_samples=%0d lead_max=%0d hints_resident=%0d hints_absent=%0d",btb_miss_errors,bht_direction_errors,btb_target_errors,lead_sum,lead_samples,lead_max,hints_resident,hints_absent);
      $display("PASS proxy");
      $finish;
    end
  end
endmodule
