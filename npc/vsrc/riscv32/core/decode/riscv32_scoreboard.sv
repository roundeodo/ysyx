// ROB 结果槽保存不同指令的值；按年龄选择最近生产者。本模块没有状态或重命名表。
module riscv32_scoreboard
  import riscv32_pkg::*;
(
    input  decoded_uop_t      issue_uop_i,
    input  xlen_data_t        rs1_i,
    rs2_i,
    input  execute_producer_t producer_array_i[BACKEND_ENTRIES],
    input  backend_tag_t      head_tag_i,
    input  logic              empty_i,
    output xlen_data_t        rs1_o,
    rs2_o,
    output logic              raw_o,
    serializing_o
);
  backend_tag_t age_array[BACKEND_ENTRIES];
  backend_tag_t rs1_age, rs2_age;
  logic rs1_match, rs2_match, rs1_ready, rs2_ready;
  for (genvar slot = 0; slot < BACKEND_ENTRIES; slot++) begin : gen_age
    assign age_array[slot] = backend_tag_t'(slot) - head_tag_i;
  end
  always_comb begin
    rs1_o         = (issue_uop_i.rs1 == '0) ? '0 : rs1_i;
    rs2_o         = (issue_uop_i.rs2 == '0) ? '0 : rs2_i;
    rs1_age       = '0;
    rs2_age       = '0;
    rs1_match     = 1'b0;
    rs2_match     = 1'b0;
    raw_o         = 1'b0;
    rs1_ready     = 1'b1;
    rs2_ready     = 1'b1;
    serializing_o = issue_uop_i.serializing && !empty_i;
    for (int slot = 0; slot < BACKEND_ENTRIES; slot++) begin
      if (producer_array_i[slot].present) begin
        serializing_o |= producer_array_i[slot].serializing;
        if (producer_array_i[slot].writes_rd && producer_array_i[slot].rd != '0) begin
          if (issue_uop_i.uses_rs1 && issue_uop_i.rs1 == producer_array_i[slot].rd &&
              (!rs1_match || age_array[slot] > rs1_age)) begin
            rs1_match = 1'b1;
            rs1_age   = age_array[slot];
            rs1_o     = producer_array_i[slot].value;
            rs1_ready = producer_array_i[slot].forwardable;
          end
          if (issue_uop_i.uses_rs2 && issue_uop_i.rs2 == producer_array_i[slot].rd &&
              (!rs2_match || age_array[slot] > rs2_age)) begin
            rs2_match = 1'b1;
            rs2_age   = age_array[slot];
            rs2_o     = producer_array_i[slot].value;
            rs2_ready = producer_array_i[slot].forwardable;
          end

        end
      end
    end
    raw_o = !rs1_ready || !rs2_ready;
    // 同 rd 的不同结果留在各自 ROB 槽，且按序写回 GPR，无需 WAW 等待。
    // RAW 只由最近的老生产者决定；所有源值在 ID/EX 入口锁存，消除 WAR 风险。
    // 非法指令不消费源值，但仍服从串行化和年龄规则。
    if (issue_uop_i.exception_valid) begin
      raw_o = 1'b0;
    end
  end
endmodule
