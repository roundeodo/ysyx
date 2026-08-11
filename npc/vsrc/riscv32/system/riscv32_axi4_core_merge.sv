// 将指令refill manager和数据访问manager合并为一个完整AXI4 manager端口。
// 读通道在AR握手后锁定请求来源，直到对应RLAST完成；数据侧独占写通道。
module riscv32_axi4_core_merge
  import riscv32_axi4_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  axi4_manager_to_target_t instruction_manager_i,
    output axi4_target_to_manager_t instruction_manager_o,

    input  axi4_manager_to_target_t data_manager_i,
    output axi4_target_to_manager_t data_manager_o,

    output axi4_manager_to_target_t downstream_manager_o,
    input  axi4_target_to_manager_t downstream_manager_i
);

  typedef enum logic {
    READ_REQUESTER_INSTRUCTION,
    READ_REQUESTER_DATA
  } read_requester_e;

  read_requester_e read_transaction_requester_q;
  read_requester_e read_transaction_requester_d;
  read_requester_e selected_read_requester;
  read_requester_e next_priority_read_requester_q;
  read_requester_e next_priority_read_requester_d;

  logic read_transaction_present_q;
  logic read_transaction_present_d;
  logic read_address_handshake;
  logic read_last_handshake;

  // 空闲时对同时到达的指令和数据读请求做轮询仲裁。事务在途时只允许已锁定
  // requester接收R通道，避免另一个manager误收同一burst中的后续beat。
  always_comb begin
    selected_read_requester = read_transaction_requester_q;

    if (!read_transaction_present_q) begin
      unique case ({data_manager_i.ar_valid, instruction_manager_i.ar_valid})
        2'b10: selected_read_requester = READ_REQUESTER_DATA;
        2'b01: selected_read_requester = READ_REQUESTER_INSTRUCTION;
        2'b11: selected_read_requester = next_priority_read_requester_q;
        default: selected_read_requester = next_priority_read_requester_q;
      endcase
    end
  end

  // 第一段：只生成下游manager请求。这个组合块不读取下游响应，避免把完整
  // request/response结构体放进同一个组合依赖环。
  always_comb begin
    downstream_manager_o = '0;

    downstream_manager_o.aw       = data_manager_i.aw;
    downstream_manager_o.aw_valid = data_manager_i.aw_valid;

    downstream_manager_o.w       = data_manager_i.w;
    downstream_manager_o.w_valid = data_manager_i.w_valid;
    downstream_manager_o.b_ready = data_manager_i.b_ready;

    if (!read_transaction_present_q) begin
      unique case (selected_read_requester)
        READ_REQUESTER_INSTRUCTION: begin
          downstream_manager_o.ar       = instruction_manager_i.ar;
          downstream_manager_o.ar_valid = instruction_manager_i.ar_valid;
        end

        READ_REQUESTER_DATA: begin
          downstream_manager_o.ar       = data_manager_i.ar;
          downstream_manager_o.ar_valid = data_manager_i.ar_valid;
        end

        default: ;
      endcase
    end

    // R通道只依据AR握手后登记的事务来源路由。AXI4没有要求target必须在AR握手
    // 当拍返回R；取消这一组合旁路后，请求选择和响应ready之间不再形成跨模块组合环。
    if (read_transaction_present_q) begin
      unique case (read_transaction_requester_q)
        READ_REQUESTER_INSTRUCTION: begin
          downstream_manager_o.r_ready = instruction_manager_i.r_ready;
        end

        READ_REQUESTER_DATA: begin
          downstream_manager_o.r_ready = data_manager_i.r_ready;
        end

        default: ;
      endcase
    end
  end

  // 指令侧只接收AR ready和属于自己的R burst。
  always_comb begin
    instruction_manager_o = '0;

    if (!read_transaction_present_q &&
        selected_read_requester == READ_REQUESTER_INSTRUCTION) begin
      instruction_manager_o.ar_ready = downstream_manager_i.ar_ready;
    end

    if (read_transaction_present_q &&
        read_transaction_requester_q == READ_REQUESTER_INSTRUCTION) begin
      instruction_manager_o.r       = downstream_manager_i.r;
      instruction_manager_o.r_valid = downstream_manager_i.r_valid;
    end
  end

  // 数据侧独占写通道，并只接收属于自己的读响应。
  always_comb begin
    data_manager_o = '0;

    data_manager_o.aw_ready = downstream_manager_i.aw_ready;
    data_manager_o.w_ready  = downstream_manager_i.w_ready;
    data_manager_o.b        = downstream_manager_i.b;
    data_manager_o.b_valid  = downstream_manager_i.b_valid;

    if (!read_transaction_present_q &&
        selected_read_requester == READ_REQUESTER_DATA) begin
      data_manager_o.ar_ready = downstream_manager_i.ar_ready;
    end

    if (read_transaction_present_q &&
        read_transaction_requester_q == READ_REQUESTER_DATA) begin
      data_manager_o.r       = downstream_manager_i.r;
      data_manager_o.r_valid = downstream_manager_i.r_valid;
    end
  end

  assign read_address_handshake =
      downstream_manager_o.ar_valid && downstream_manager_i.ar_ready;
  assign read_last_handshake = downstream_manager_i.r_valid &&
                               downstream_manager_o.r_ready &&
                               downstream_manager_i.r.last;

  // 第二段：只记录读事务来源和下一次竞争的优先方。这里不按ID重新排序，
  // 当前实现最多允许一个读burst在互联中在途；接口和ID语义仍为后续多在途保留。
  always_comb begin
    read_transaction_requester_d = read_transaction_requester_q;
    next_priority_read_requester_d = next_priority_read_requester_q;
    read_transaction_present_d = read_transaction_present_q;

    if (!read_transaction_present_q && read_address_handshake) begin
      read_transaction_requester_d = selected_read_requester;
      read_transaction_present_d   = 1'b1;
    end

    if (read_last_handshake) begin
      read_transaction_present_d = 1'b0;
      unique case (read_transaction_requester_q)
        READ_REQUESTER_INSTRUCTION:
          next_priority_read_requester_d = READ_REQUESTER_DATA;
        READ_REQUESTER_DATA:
          next_priority_read_requester_d = READ_REQUESTER_INSTRUCTION;
        default:
          next_priority_read_requester_d = READ_REQUESTER_INSTRUCTION;
      endcase
    end
  end

  // 第三段：事务锁和轮询状态分组更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_transaction_present_q   <= 1'b0;
      read_transaction_requester_q <= READ_REQUESTER_INSTRUCTION;
    end else begin
      read_transaction_present_q   <= read_transaction_present_d;
      read_transaction_requester_q <= read_transaction_requester_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      next_priority_read_requester_q <= READ_REQUESTER_INSTRUCTION;
    end else begin
      next_priority_read_requester_q <= next_priority_read_requester_d;
    end
  end

endmodule
