module riscv_config_elaboration_tb;
  import riscv_config_pkg::*;

  initial begin
    assert (INSTR_WIDTH == 32);
    assert (PADDR_WIDTH == 32);
    assert (ARCH_REG_COUNT == 32);

    assert (XLEN == 64);
    assert (CORE_DATA_WIDTH == 64);
    assert (MEM_AXI_DATA_WIDTH == 64);
    assert (YSYX_SOC_AXI_DATA_WIDTH == 32);
    assert (DCACHE_ENABLED);

    $finish;
  end
endmodule : riscv_config_elaboration_tb
