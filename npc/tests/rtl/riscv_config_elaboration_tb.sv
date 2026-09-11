module riscv_config_elaboration_tb;
  import riscv_config_pkg::*;

  initial begin
    assert (CONFIG_SELECTION_COUNT == 1)
      else $fatal(1, "exactly one NPC configuration must be selected");
    assert (INSTR_WIDTH == 32);
    assert (PADDR_WIDTH == 32);
    assert (ARCH_REG_COUNT == 32);

`ifdef YSYX_RV32_BASELINE
    assert (XLEN == 32);
    assert (CORE_DATA_WIDTH == 32);
    assert (MEM_AXI_DATA_WIDTH == 32);
    assert (YSYX_SOC_AXI_DATA_WIDTH == 32);
`elsif YSYX_RV64_SEQUENTIAL
    assert (XLEN == 64);
    assert (CORE_DATA_WIDTH == 64);
    assert (MEM_AXI_DATA_WIDTH == 64);
    assert (YSYX_SOC_AXI_DATA_WIDTH == 32);
`endif

`ifdef YSYX_RV32_COURSE_AREA
    assert (!DCACHE_ENABLED);
    assert (ICACHE_CAPACITY_BYTES == 64);
`endif

    $finish;
  end
endmodule : riscv_config_elaboration_tb
