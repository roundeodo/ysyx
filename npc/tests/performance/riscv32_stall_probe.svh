// 仅由 measure_lsu_stalls.py 注入冻结的仿真副本，不在正式 filelist 中。
// 所有层级引用均只读；按上升沿前状态累计，在原生 CLINT 低字读握手前导出快照。
// 一个互斥派发分类 + 可重叠事件。后者不能相加作为节省周期。
`ifdef VERILATOR
`define STALL_CORE u_core
`define STALL_BACK u_core.gen_rob_backend.u_backend
`define STALL_DC u_core.u_data_mem.gen_dcache.u_dcache
if (BACKEND_ROB_ENABLE && DCACHE_ENABLED) begin : gen_stall_probe
  integer output_file;
  string output_path;
  longint unsigned cycles, retired;
  longint unsigned category_count[12];
  longint unsigned event_count[38];
  string category_name[12] = '{"dispatch", "control", "memory_order", "discard_drain",
      "lsu_capacity", "divider_busy", "execute_other", "serializing", "raw",
      "rob_full", "issue_transfer", "frontend_empty"};
  string event_name[38] = '{"lsu_pending", "dc_miss_busy", "ic_miss_busy", "rob_full",
      "raw_load", "head_wait_load", "head_wait_store", "head_wait_other",
      "lsu_wait_load", "lsu_wait_store", "load_wait_during_miss", "wait_same_line",
      "wait_other_line_hit", "wait_other_line_miss", "ready_younger_alu_mul_div",
      "ready_younger_with_rob_space", "dc_lookup", "dc_miss", "dc_dirty_miss",
      "load_dispatch", "store_dispatch", "control_redirect", "retire",
      "lsu_wait_episodes", "head_ready", "rob_occupancy_sum",
      "raw_category_load", "raw_category_other", "order_lsu_busy", "order_lsu_ready",
      "order_dcache_miss", "order_pending_uncached", "head_wait_store_uncached",
      "head_wait_load_dcache_miss", "lsu_two_pending", "lsu_overlap_accept",
      "dc_hit_under_miss", "dc_wait_refill"};
  logic [37:0] events;
  logic raw_load, queued_load_wait, shadow_hit, same_line, wait_previous;
  logic snapshot;
  int category, set_index, producer_index;
  phys_addr_t waiting_address;
  dcache_tag_t waiting_tag;
  longint unsigned pc_wait_count[program_counter_t];

  initial begin
    output_file = 0;
    if ($value$plusargs("NPC_STALL_OUTPUT=%s", output_path)) begin
      output_file = $fopen(output_path, "w");
      if (!output_file) $fatal(1, "Cannot open stall observation output");
    end
  end

  // 主分类只描述当前无法向 FU 派发的首要条件；已派发优先，控制恢复其次。
  always_comb begin
    category = 11;
    if (`STALL_BACK.dispatch_handshake) category = 0;
    else if (!`STALL_BACK.issue_allowed_o || `STALL_BACK.issue_hold_i ||
             `STALL_BACK.sequential_redirect_valid_o) category = 1;
    else if (`STALL_BACK.execute_valid_o) begin
      if (`STALL_BACK.memory_selected && !`STALL_BACK.memory_safe) category = 2;
      else if (`STALL_BACK.memory_selected && LSU_ENTRIES == 1 && `STALL_BACK.lsu_discard_q) category = 3;
      else if (`STALL_BACK.memory_selected && !`STALL_BACK.lsu_ready_i) category = 4;
      else if (`STALL_BACK.divide_selected && !`STALL_BACK.dispatch_ready) category = 5;
      else category = 6;
    end else if (`STALL_BACK.issue_valid_i) begin
      if (`STALL_BACK.serializing_o) category = 7;
      else if (`STALL_BACK.raw_o) category = 8;
      else if (!`STALL_BACK.allocate_ready) category = 9;
      else category = 10;
    end
  end

  // 仿真影子查询：检查被 LSU 拒绝的普通 load 地址当前是否在 D-cache 中。
  // 不驱动真实阵列读口，不代表已实现 hit-under-miss，也不计作真实 cache hit。
  always_comb begin
    waiting_address = phys_addr_t'(`STALL_BACK.lsu_req_o.effective_addr);
    set_index = int'((waiting_address >> DCACHE_LINE_OFFSET_W) & (DCACHE_SET_COUNT - 1));
    waiting_tag = dcache_tag_t'(waiting_address >> (DCACHE_LINE_OFFSET_W + DCACHE_SET_INDEX_BITS));
    shadow_hit = 1'b0;
    for (int way = 0; way < DCACHE_WAY_COUNT; way++) begin
      shadow_hit |= `STALL_DC.u_tag_array.line_present_array_q[way][set_index] &&
                    `STALL_DC.u_tag_array.tag_array_q[way][set_index] == waiting_tag;
    end
    same_line = (waiting_address >> DCACHE_LINE_OFFSET_W) ==
        (`STALL_DC.u_miss_unit.miss_context_q.memory_req.addr >> DCACHE_LINE_OFFSET_W);
    queued_load_wait = category == 4 &&
        `STALL_BACK.execute_packet_o.uop.mem_ctrl.cmd == MEM_CMD_LOAD &&
        `STALL_BACK.memory_attr.readable && `STALL_BACK.memory_attr.cacheable &&
        `STALL_BACK.memory_attr.idempotent;

    raw_load = 1'b0;
    producer_index = 0;
    if (`STALL_BACK.issue_valid_i && `STALL_BACK.raw_o) begin
      if (!`STALL_BACK.u_scoreboard.rs1_ready) begin
        producer_index = int'(backend_tag_t'(`STALL_BACK.head_tag +
                                            `STALL_BACK.u_scoreboard.rs1_age));
        raw_load |= `STALL_BACK.u_rob.result_array_q[producer_index].uop.mem_ctrl.cmd == MEM_CMD_LOAD;
      end
      if (!`STALL_BACK.u_scoreboard.rs2_ready) begin
        producer_index = int'(backend_tag_t'(`STALL_BACK.head_tag +
                                            `STALL_BACK.u_scoreboard.rs2_age));
        raw_load |= `STALL_BACK.u_rob.result_array_q[producer_index].uop.mem_ctrl.cmd == MEM_CMD_LOAD;
      end
    end
    events = '0;
    events[0] = `STALL_BACK.lsu_pending_q;
    events[1] = `STALL_DC.miss_transaction_present;
    events[2] = `STALL_CORE.u_icache.miss_transaction_present;
    events[3] = !`STALL_BACK.allocate_ready;
    events[4] = raw_load;
    events[5] = !`STALL_BACK.empty && !`STALL_BACK.head_valid_o &&
        `STALL_BACK.head_o.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
    events[6] = !`STALL_BACK.empty && !`STALL_BACK.head_valid_o &&
        `STALL_BACK.head_o.uop.mem_ctrl.cmd == MEM_CMD_STORE;
    events[7] = !`STALL_BACK.empty && !`STALL_BACK.head_valid_o && !events[5] && !events[6];
    events[8] = category == 4 && `STALL_BACK.execute_packet_o.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
    events[9] = category == 4 && `STALL_BACK.execute_packet_o.uop.mem_ctrl.cmd == MEM_CMD_STORE;
    events[10] = queued_load_wait && events[1];
    events[11] = events[10] && same_line;
    events[12] = events[10] && !same_line && shadow_hit;
    events[13] = events[10] && !same_line && !shadow_hit;
    events[14] = category == 4 && `STALL_BACK.issue_valid_i && !`STALL_BACK.raw_o &&
        !`STALL_BACK.serializing_o && (`STALL_BACK.issue_uop.fu_type inside {FU_INT, FU_MULDIV});
    events[15] = events[14] && `STALL_BACK.allocate_ready;
    events[16] = `STALL_CORE.dcache_event.lookup_event;
    events[17] = `STALL_CORE.dcache_event.miss_event;
    events[18] = `STALL_CORE.dcache_event.dirty_victim_miss_event;
    events[19] = `STALL_BACK.memory_handshake && `STALL_BACK.execute_packet_o.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
    events[20] = `STALL_BACK.memory_handshake && `STALL_BACK.execute_packet_o.uop.mem_ctrl.cmd == MEM_CMD_STORE;
    events[21] = `STALL_CORE.frontend_recovery_event;
    events[22] = `STALL_CORE.retired_instruction_event;
    events[23] = category == 4 && !wait_previous;
    events[24] = `STALL_BACK.head_valid_o;
    // event 25 是占用项数的累计，非布尔周期数。
    events[26] = category == 8 && raw_load;
    events[27] = category == 8 && !raw_load;
    events[28] = category == 2 && !`STALL_BACK.lsu_ready_i;
    events[29] = category == 2 && `STALL_BACK.lsu_ready_i;
    events[30] = category == 2 && events[1];
    events[31] = category == 2 && `STALL_CORE.u_data_mem.route_state_q == `STALL_CORE.u_data_mem.DATA_ROUTE_UNCACHED;
    events[32] = events[6] && `STALL_CORE.u_data_mem.route_state_q == `STALL_CORE.u_data_mem.DATA_ROUTE_UNCACHED;
    events[33] = events[5] && events[1];
    events[34] = $countones(`STALL_BACK.lsu_pending_vector_q) > 1;
    events[35] = `STALL_BACK.memory_handshake &&
        ($countones(`STALL_BACK.lsu_pending_vector_q) > int'(`STALL_BACK.lsu_result_valid_i));
    events[36] = `STALL_DC.local_resp_handshake && `STALL_DC.miss_transaction_present;
    events[37] = `STALL_DC.lookup_wait_refill_q;
  end

  assign snapshot = u_clint.read_address_handshake &&
      u_clint.axi_target_i.ar.addr == 32'h0200_0048 &&
      u_clint.axi_target_i.ar.len == 0 && u_clint.axi_target_i.ar.size == 3'd2 &&
      (u_clint.axi_target_i.ar.burst inside {2'b00, 2'b01});

  task automatic emit(input string kind);
    $fwrite(output_file, "{\"type\":\"%s\",\"cycles\":%0d,\"retired\":%0d,\"ticks\":%0d,\"categories\":{",
            kind, cycles, retired, u_clint.mtime_q);
    for (int index = 0; index < 12; index++)
      $fwrite(output_file, "%s\"%s\":%0d", index == 0 ? "" : ",", category_name[index], category_count[index]);
    $fwrite(output_file, "},\"events\":{");
    for (int index = 0; index < 38; index++)
      $fwrite(output_file, "%s\"%s\":%0d", index == 0 ? "" : ",", event_name[index], event_count[index]);
    $fwrite(output_file, "}}\n");
    $fflush(output_file);
  endtask

  // 此处为纯仿真统计，快照先于本拍更新，差分严格对应 [begin_edge,end_edge)。
  always @(posedge clk_i) begin
    if (!system_rst_n) begin
      cycles = 0;
      retired = 0;
      wait_previous = 1'b0;
      foreach (category_count[index]) category_count[index] = 0;
      foreach (event_count[index]) event_count[index] = 0;
      pc_wait_count.delete();
    end else if (output_file != 0) begin
      if (snapshot) emit("snapshot");
      cycles++;
      retired += 64'(`STALL_CORE.retired_instruction_event);
      category_count[category]++;
      for (int index = 0; index < 38; index++)
        if (index != 25) event_count[index] += 64'(events[index]);
      event_count[25] += 64'(`STALL_BACK.count);
      if (category == 4) begin
        if (!pc_wait_count.exists(`STALL_BACK.execute_packet_o.uop.pc))
          pc_wait_count[`STALL_BACK.execute_packet_o.uop.pc] = 0;
        pc_wait_count[`STALL_BACK.execute_packet_o.uop.pc]++;
      end
      wait_previous = category == 4;
    end
  end
  final begin
    if (output_file != 0) begin
      emit("finish");
      foreach (pc_wait_count[pc])
        $fwrite(output_file, "{\"type\":\"pc_wait\",\"pc\":%0d,\"cycles\":%0d}\n", pc, pc_wait_count[pc]);
      $fclose(output_file);
    end
  end
end
`undef STALL_CORE
`undef STALL_BACK
`undef STALL_DC
`endif
