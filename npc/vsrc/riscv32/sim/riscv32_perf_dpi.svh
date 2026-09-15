// Read-only simulation interface, shared by the standalone and SoC wrappers.
// Called after clock-low evaluation, before the next rising edge. No state or
// output of this interface feeds back into the processor or the CLINT.
`ifdef VERILATOR
  export "DPI-C" function npc_get_perf_flags_dpi;
  export "DPI-C" function npc_get_perf_timer_dpi;
  export "DPI-C" function npc_get_perf_load_pc_dpi;
  export "DPI-C" function npc_get_perf_cpu_hz_dpi;
  export "DPI-C" function npc_get_perf_timer_hz_dpi;
  export "DPI-C" function npc_get_commit_audit_dpi;

  function int npc_get_perf_flags_dpi();
    logic [4:0] flags;
    flags = '0;
    if (u_npc_system.system_rst_n) begin
      flags[0] = u_npc_system.u_core.retired_instruction_occurred;
      // Match the CLINT's legal RV32 low-word sample, not R-channel delivery.
      flags[1] = u_npc_system.u_clint.read_address_handshake &&
          (u_npc_system.u_clint.axi_target_i.ar.addr == 32'h0200_0048) &&
          (u_npc_system.u_clint.axi_target_i.ar.len == 0) &&
          (u_npc_system.u_clint.axi_target_i.ar.size == 3'd2) &&
          (u_npc_system.u_clint.axi_target_i.ar.burst inside {2'b00, 2'b01});
      // Any CLINT write makes the default MicroBench timing audit fail closed.
      flags[2] = u_npc_system.u_clint.register_write_valid;
      flags[3] = u_npc_system.u_core.interrupt_valid;
      flags[4] = u_npc_system.u_core.commit_valid &&
          u_npc_system.u_core.commit.trap_taken;
    end
    return int'(flags);
  endfunction

  function longint unsigned npc_get_perf_timer_dpi();
    return u_npc_system.u_clint.mtime_q;
  endfunction

  function longint unsigned npc_get_perf_load_pc_dpi();
    return 64'($unsigned(u_npc_system.u_core.u_lsu.pending_lsu_context_q.pc));
  endfunction

  function longint unsigned npc_get_perf_cpu_hz_dpi();
    return 64'(u_npc_system.CLINT_CLOCK_FREQ_HZ);
  endfunction

  function longint unsigned npc_get_perf_timer_hz_dpi();
    return 64'(u_npc_system.MTIME_INCREMENT_FREQ_HZ);
  endfunction

  // Optional short-test audit of architectural writes and memory side effects.
  // Packed control bits keep invalid data fields out of the host digest.
  function longint unsigned npc_get_commit_audit_dpi(input int index);
    case (index)
      0: return 64'({u_npc_system.u_core.commit.gpr_write,
                     u_npc_system.u_core.commit.gpr_addr,
                     u_npc_system.u_core.commit.csr_write,
                     u_npc_system.u_core.commit.csr_addr,
                     u_npc_system.u_core.commit.memory_access,
                     u_npc_system.u_core.commit.memory_cmd,
                     u_npc_system.u_core.commit.memory_size,
                     u_npc_system.u_core.commit.memory_wmask});
      1: return u_npc_system.u_core.commit.gpr_write ?
          64'($unsigned(u_npc_system.u_core.commit.gpr_wdata)) : 0;
      2: return u_npc_system.u_core.commit.csr_write ?
          64'($unsigned(u_npc_system.u_core.commit.csr_wdata)) : 0;
      3: return u_npc_system.u_core.commit.memory_access ?
          64'($unsigned(u_npc_system.u_core.commit.memory_addr)) : 0;
      4: return u_npc_system.u_core.commit.memory_access ?
          64'($unsigned(u_npc_system.u_core.commit.memory_wdata)) : 0;
      5: return u_npc_system.u_core.commit.memory_access ?
          64'($unsigned(u_npc_system.u_core.commit.memory_rdata)) : 0;
      default: return 0;
    endcase
  endfunction
`endif
