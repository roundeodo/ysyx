// ID/EX解耦队列。它保存已经完成译码和寄存器读取的执行payload，
// 不负责译码、冒险判断或执行；这些职责分别属于IDU、hazard controller和EXU。
//
// 两个入口使输入ready只依赖本级寄存状态，不再组合穿过EXU、EX/MEM和WB。
// 队列通常同时入队和出队，仍可维持每周期一条指令的吞吐。
module riscv32_decode_execute_stage
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  execute_packet_t decoded_execute_packet_i,
    input  logic            decoded_execute_packet_valid_i,
    output logic            decoded_execute_packet_ready_o,

    output execute_packet_t execute_packet_o,
    output logic            execute_packet_valid_o,
    input  logic            execute_packet_ready_i,

    // flush删除尚未产生架构副作用的年轻指令。当前EX级分支自身已经离开本队列，
    // 因此清空两个入口不会删除产生redirect的指令。
    input logic flush_i
);

  localparam int unsigned ENTRY_COUNT = 2;

  execute_packet_t execute_packet_array_q [ENTRY_COUNT];
  logic            read_entry_index_q;
  logic            read_entry_index_d;
  logic            write_entry_index_q;
  logic            write_entry_index_d;
  logic [1:0]      stored_entry_count_q;
  logic [1:0]      stored_entry_count_d;
  logic            input_handshake_occurred;
  logic            output_handshake_occurred;

  // 即使队列本周期正在出队，满队列也暂不组合返回ready。这个选择主动切断
  // 下游ready路径；稳态一入一出时队列占用通常为1，不会损失吞吐。
  assign decoded_execute_packet_ready_o = (stored_entry_count_q != 2'd2) && !flush_i;
  assign execute_packet_valid_o         = stored_entry_count_q != 0;
  assign execute_packet_o               = execute_packet_array_q[read_entry_index_q];

  assign input_handshake_occurred = decoded_execute_packet_valid_i &&
                                    decoded_execute_packet_ready_o;
  assign output_handshake_occurred = execute_packet_valid_o && execute_packet_ready_i;

  always_comb begin
    read_entry_index_d   = read_entry_index_q;
    write_entry_index_d  = write_entry_index_q;
    stored_entry_count_d = stored_entry_count_q;

    if (input_handshake_occurred) begin
      write_entry_index_d = write_entry_index_q + 1'b1;
    end

    if (output_handshake_occurred) begin
      read_entry_index_d = read_entry_index_q + 1'b1;
    end

    unique case ({input_handshake_occurred, output_handshake_occurred})
      2'b10: stored_entry_count_d = stored_entry_count_q + 1'b1;
      2'b01: stored_entry_count_d = stored_entry_count_q - 1'b1;
      default: ;
    endcase

    // 恢复优先级最高：错误路径payload不得在flush边沿后继续有效。
    if (flush_i) begin
      read_entry_index_d   = 1'b0;
      write_entry_index_d  = 1'b0;
      stored_entry_count_d = '0;
    end
  end

  // payload无需复位；stored_entry_count_q=0时数组内容没有架构语义。
  always_ff @(posedge clk_i) begin
    if (input_handshake_occurred) begin
      execute_packet_array_q[write_entry_index_q] <= decoded_execute_packet_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_entry_index_q   <= 1'b0;
      write_entry_index_q  <= 1'b0;
      stored_entry_count_q <= '0;
    end else begin
      read_entry_index_q   <= read_entry_index_d;
      write_entry_index_q  <= write_entry_index_d;
      stored_entry_count_q <= stored_entry_count_d;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    stored_entry_count_q <= 2'd2)
  else $error("ID/EX queue occupancy exceeded its capacity");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (execute_packet_valid_o && !execute_packet_ready_i && !flush_i)
    |=> (execute_packet_valid_o && $stable(execute_packet_o)))
  else $error("ID/EX queue changed its head payload while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !execute_packet_valid_o)
  else $error("ID/EX queue retained a flushed instruction");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
