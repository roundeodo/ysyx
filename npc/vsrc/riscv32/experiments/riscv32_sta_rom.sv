// STA-only 256x32 instruction memory for the ysyx single-cycle frequency exercise.
// It intentionally has a combinational read and no bus handshake.
module riscv32_sta_rom #(
    parameter int unsigned DEPTH_WORDS = 256,
    parameter int unsigned ADDR_W      = $clog2(DEPTH_WORDS)
) (
    input  logic [ADDR_W-1:0] raddr_i,
    output logic [      31:0] rdata_o
);

  // TODO(STA-ROM-ARRAY): 在本位置声明 256x32-bit 寄存器阵列，例如：
  //   logic [31:0] mem_q [0:DEPTH_WORDS-1];
  // 此处用触发器/寄存器阵列描述 memory，只是为了把“组合存储器读取路径”包含进
  // 单周期 NPC 的综合结果，不用于运行 microbench、AM 或 RT-Thread。

  // TODO(STA-ROM-READ): 在本位置实现当前周期返回数据的组合读取：
  //   assign rdata_o = mem_q[raddr_i];
  // 不要增加 always_ff、valid/ready 或一拍延迟，否则测到的就不再是手册要求的
  // 单周期 NPC + register-array memory 主频。

endmodule
