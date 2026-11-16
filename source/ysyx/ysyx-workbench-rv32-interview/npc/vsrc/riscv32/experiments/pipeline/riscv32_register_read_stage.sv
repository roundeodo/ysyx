// 历史流水级实验：当前 riscv32_core 不实例化此模块。
// 寄存器读取流水级。输入是已经完成译码的uop及其原始寄存器/CSR读值，输出是在
// 独立时钟沿锁存后的执行包。该边界把架构寄存器堆的异步读选择与后续前递、冒险
// 判断和ID/EX宽payload写入分开，使寄存器索引到执行级不再跨越两组选择网络。
module riscv32_register_read_stage
  import riscv32_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    input  execute_packet_t decoded_register_read_packet_i,
    input  logic            decoded_register_read_packet_valid_i,
    output logic            decoded_register_read_packet_ready_o,

    output execute_packet_t register_read_packet_o,
    output logic            register_read_packet_valid_o,
    input  logic            register_read_packet_ready_i,

    input  logic          gpr_write_enable_i,
    input  arch_reg_idx_t gpr_write_addr_i,
    input  xlen_data_t    gpr_write_data_i,

    input  logic flush_i
);

  execute_packet_t register_read_packet_q;
  logic            register_read_packet_valid_q;

  // 单项弹性寄存器在下游消费当前项的同一拍允许接收下一项，因此稳态吞吐仍为1条/拍。
  // ready只穿过本级一个valid位和下游ID/EX容量信号，不进入寄存器堆数据选择路径。
  assign decoded_register_read_packet_ready_o = !register_read_packet_valid_q ||
      register_read_packet_ready_i;
  assign register_read_packet_o       = register_read_packet_q;
  assign register_read_packet_valid_o = register_read_packet_valid_q;

  // payload有空间时接收新指令。若当前指令被反压，仍监听架构寄存器回写并更新命中的
  // 源操作数快照，避免消费者等待其他结构资源期间错过生产者的WB周期。该监听只比较
  // 两个5位寄存器号，不会把寄存器堆的32选1读mux重新接回ID/EX关键路径。
  always_ff @(posedge clk_i) begin
    if (decoded_register_read_packet_ready_o) begin
      register_read_packet_q <= decoded_register_read_packet_i;
    end else if (register_read_packet_valid_q && gpr_write_enable_i &&
                 (gpr_write_addr_i != arch_reg_idx_t'(0))) begin
      if (register_read_packet_q.uop.uses_rs1 &&
          (register_read_packet_q.uop.rs1 == gpr_write_addr_i)) begin
        register_read_packet_q.source_a_value <= gpr_write_data_i;
      end
      if (register_read_packet_q.uop.uses_rs2 &&
          (register_read_packet_q.uop.rs2 == gpr_write_addr_i)) begin
        register_read_packet_q.source_b_value <= gpr_write_data_i;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      register_read_packet_valid_q <= 1'b0;
    end else if (flush_i) begin
      register_read_packet_valid_q <= 1'b0;
    end else if (decoded_register_read_packet_ready_o) begin
      register_read_packet_valid_q <= decoded_register_read_packet_valid_i;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (register_read_packet_valid_o && !register_read_packet_ready_i && !flush_i &&
     !gpr_write_enable_i)
    |=> (register_read_packet_valid_o && $stable(register_read_packet_o)))
  else
    $error("register-read stage changed packet while backpressured without a GPR write");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !register_read_packet_valid_o)
  else
    $error("register-read stage retained a flushed instruction");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
