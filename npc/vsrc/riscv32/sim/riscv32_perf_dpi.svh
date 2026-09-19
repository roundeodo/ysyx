// standalone 和 SoC 共用的只读 DPI 接口。宿主在时钟低电平求值后、下一上升沿前采样。
// 不插入 CPU 指令，不读取软件 CSR，也不向 CPU 或 CLINT 反馈控制。
`ifdef VERILATOR
  export "DPI-C" function npc_get_perf_flags_dpi;
  export "DPI-C" function npc_get_perf_timer_dpi;
  export "DPI-C" function npc_get_perf_load_pc_dpi;
  export "DPI-C" function npc_get_perf_cpu_hz_dpi;
  export "DPI-C" function npc_get_perf_timer_hz_dpi;
  export "DPI-C" function npc_get_commit_audit_dpi;

  function int npc_get_perf_flags_dpi();
    logic [4:0] event_flags;
    event_flags = '0;
    if (u_npc_system.system_rst_n) begin
      event_flags[0] = u_npc_system.u_core.retired_instruction_event;
      // bit 1 对应 CLINT 接受合法 RV32 mtime 低字读取的时刻。
      event_flags[1] = u_npc_system.u_clint.read_address_handshake &&
          (u_npc_system.u_clint.axi_target_i.ar.addr == 32'h0200_0048) &&
          (u_npc_system.u_clint.axi_target_i.ar.len == 0) &&
          (u_npc_system.u_clint.axi_target_i.ar.size == 3'd2) &&
          (u_npc_system.u_clint.axi_target_i.ar.burst inside {2'b00, 2'b01});
      // bit 2 记录 CLINT 写入；宿主据此拒绝将被改写的计时器用于默认测量。
      event_flags[2] = u_npc_system.u_clint.register_write_valid;
      event_flags[3] = u_npc_system.u_core.interrupt_valid;
      event_flags[4] = u_npc_system.u_core.commit_valid &&
          u_npc_system.u_core.commit.trap_taken;
    end
    return int'(event_flags);
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

  // 短测试的提交审计：索引 0 返回控制字段，1..5 返回寄存器与访存数据。
  // 无效字段返回 0，避免未生效的载荷影响宿主摘要；函数名和索引属于固定 DPI 接口。
  function longint unsigned npc_get_commit_audit_dpi(input int field_index);
    case (field_index)
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
