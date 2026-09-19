// 纯组合操作数准备：语义源选择 → 前递覆盖 → ID/EX 输入包。此模块没有寄存器。
module riscv32_operand_mux
  import riscv32_pkg::*;
(
    input  decoded_uop_t    decoded_uop_i,
    input  xlen_data_t      rs1_value_i,
    input  xlen_data_t      rs2_value_i,
    input  xlen_data_t      csr_read_data_i,
    input  logic            csr_read_illegal_i,
    input  xlen_data_t      execute_forwarding_value_i,
    input  xlen_data_t      execute_result_forwarding_value_i,
    input  xlen_data_t      lsu_forwarding_value_i,
    input  xlen_data_t      writeback_forwarding_value_i,
    input  logic            rs1_execute_forwarding_selected_i,
    input  logic            rs1_execute_result_forwarding_selected_i,
    input  logic            rs1_lsu_forwarding_selected_i,
    input  logic            rs1_writeback_forwarding_selected_i,
    input  logic            rs2_execute_forwarding_selected_i,
    input  logic            rs2_execute_result_forwarding_selected_i,
    input  logic            rs2_lsu_forwarding_selected_i,
    input  logic            rs2_writeback_forwarding_selected_i,
    output execute_packet_t decoded_execute_packet_o
);
  always_comb begin
    decoded_execute_packet_o                = '0;
    decoded_execute_packet_o.uop            = decoded_uop_i;
    decoded_execute_packet_o.source_a_value = rs1_value_i;
    decoded_execute_packet_o.source_b_value = rs2_value_i;
    decoded_execute_packet_o.csr_rdata      = csr_read_data_i;
    decoded_execute_packet_o.csr_illegal    = csr_read_illegal_i;

    // 整数操作数选择在ID/EX寄存边界之前完成。其他执行类型仍需要真实rs1/rs2：
    // branch用它们比较，LSU用它们形成地址/写数据，CSR用source_a形成寄存器操作数。
    if (decoded_uop_i.fu_type == FU_INT) begin
      unique case (decoded_uop_i.int_ctrl.operand_a_select)
        OPA_RS1: decoded_execute_packet_o.source_a_value = rs1_value_i;
        OPA_PC:  decoded_execute_packet_o.source_a_value =
            xlen_data_t'(decoded_uop_i.pc);
        default: decoded_execute_packet_o.source_a_value = '0;
      endcase

      unique case (decoded_uop_i.int_ctrl.operand_b_select)
        OPB_RS2: decoded_execute_packet_o.source_b_value = rs2_value_i;
        OPB_IMM: decoded_execute_packet_o.source_b_value = decoded_uop_i.imm;
        default: decoded_execute_packet_o.source_b_value = '0;
      endcase
    end

    // 冒险控制器选择最近的可用生产者：EX、EX 结果、LSU 完成、WB。
    if (rs1_writeback_forwarding_selected_i) begin
      decoded_execute_packet_o.source_a_value = writeback_forwarding_value_i;
    end
    if (rs2_writeback_forwarding_selected_i) begin
      decoded_execute_packet_o.source_b_value = writeback_forwarding_value_i;
    end
    if (rs1_lsu_forwarding_selected_i)
      decoded_execute_packet_o.source_a_value = lsu_forwarding_value_i;
    if (rs2_lsu_forwarding_selected_i)
      decoded_execute_packet_o.source_b_value = lsu_forwarding_value_i;
    if (rs1_execute_result_forwarding_selected_i) begin
      decoded_execute_packet_o.source_a_value = execute_result_forwarding_value_i;
    end
    if (rs2_execute_result_forwarding_selected_i) begin
      decoded_execute_packet_o.source_b_value = execute_result_forwarding_value_i;
    end
    if (rs1_execute_forwarding_selected_i) begin
      decoded_execute_packet_o.source_a_value = execute_forwarding_value_i;
    end
    if (rs2_execute_forwarding_selected_i) begin
      decoded_execute_packet_o.source_b_value = execute_forwarding_value_i;
    end
  end
endmodule
