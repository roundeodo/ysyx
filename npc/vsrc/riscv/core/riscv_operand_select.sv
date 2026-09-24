// 选择进入读寄存器级与ID/EX的操作数。只负责数据选择；相关比较和允许条件由冒险控制器给出。
module riscv_operand_select
  import riscv_pkg::*;
(
    input  decoded_uop_t    decoded_uop_i,
    input  xlen_data_t      rs1_value_i,
    input  xlen_data_t      rs2_value_i,
    input  logic            gpr_write_enable_i,
    input  arch_reg_idx_t   gpr_write_addr_i,
    input  xlen_data_t      gpr_write_data_i,
    input  execute_packet_t register_read_packet_i,
    input  xlen_data_t      csr_read_data_i,
    input  logic            csr_read_illegal_i,
    input  logic            rs1_writeback_forwarding_selected_i,
    input  logic            rs2_writeback_forwarding_selected_i,
    input  logic            rs1_execute_result_forwarding_selected_i,
    input  logic            rs2_execute_result_forwarding_selected_i,
    input  logic            rs1_execute_forwarding_selected_i,
    input  logic            rs2_execute_forwarding_selected_i,
    input  xlen_data_t      execute_value_i,
    input  xlen_data_t      execute_result_value_i,
    input  xlen_data_t      writeback_value_i,
    output execute_packet_t decoded_register_read_packet_o,
    output execute_packet_t decoded_execute_packet_o
);
  always_comb begin
    decoded_register_read_packet_o                = '0;
    decoded_register_read_packet_o.uop            = decoded_uop_i;
    decoded_register_read_packet_o.source_a_value =
        (gpr_write_enable_i && (gpr_write_addr_i == decoded_uop_i.rs1) && (decoded_uop_i.rs1 != '0)) ?
        gpr_write_data_i : rs1_value_i;
    decoded_register_read_packet_o.source_b_value =
        (gpr_write_enable_i && (gpr_write_addr_i == decoded_uop_i.rs2) && (decoded_uop_i.rs2 != '0)) ?
        gpr_write_data_i : rs2_value_i;
    decoded_register_read_packet_o.csr_rdata      = '0;
    decoded_register_read_packet_o.csr_illegal    = 1'b0;

    decoded_execute_packet_o             = register_read_packet_i;
    decoded_execute_packet_o.csr_rdata   = csr_read_data_i;
    decoded_execute_packet_o.csr_illegal = csr_read_illegal_i;

    // 整数操作数选择在ID/EX寄存边界之前完成。其他执行类型仍需要真实rs1/rs2：
    // branch用它们比较，LSU用它们形成地址/写数据，CSR用source_a形成寄存器操作数。
    if (register_read_packet_i.uop.fu_type == FU_INT) begin
      unique case (register_read_packet_i.uop.int_ctrl.operand_a_sel)
        OPA_RS1: decoded_execute_packet_o.source_a_value = register_read_packet_i.source_a_value;
        OPA_PC:
        decoded_execute_packet_o.source_a_value = xlen_data_t'(register_read_packet_i.uop.pc);
        default: decoded_execute_packet_o.source_a_value = '0;
      endcase

      unique case (register_read_packet_i.uop.int_ctrl.operand_b_sel)
        OPB_RS2: decoded_execute_packet_o.source_b_value = register_read_packet_i.source_b_value;
        OPB_IMM: decoded_execute_packet_o.source_b_value = register_read_packet_i.uop.imm;
        default: decoded_execute_packet_o.source_b_value = '0;
      endcase
    end

    // 所有旁路都在消费者写入ID/EX时完成。当前EX生产者的组合结果在该时钟沿前已经
    // 稳定，可以和EX/MEM、WB结果一样直接写入payload。LSU结果必须先跨过WB寄存边界，
    // 避免把存储系统response与ID/EX操作数选择串成关键路径。这样普通相关指令仍可连续
    // 发射，同时不把“旁路mux + 当前指令ALU”串在同一条EX关键路径上。
    if (rs1_writeback_forwarding_selected_i) begin
      decoded_execute_packet_o.source_a_value = writeback_value_i;
    end
    if (rs2_writeback_forwarding_selected_i) begin
      decoded_execute_packet_o.source_b_value = writeback_value_i;
    end
    if (rs1_execute_result_forwarding_selected_i) begin
      decoded_execute_packet_o.source_a_value = execute_result_value_i;
    end
    if (rs2_execute_result_forwarding_selected_i) begin
      decoded_execute_packet_o.source_b_value = execute_result_value_i;
    end
    if (rs1_execute_forwarding_selected_i) begin
      decoded_execute_packet_o.source_a_value = execute_value_i;
    end
    if (rs2_execute_forwarding_selected_i) begin
      decoded_execute_packet_o.source_b_value = execute_value_i;
    end
  end

endmodule
