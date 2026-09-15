// ID/EX流水级寄存器。它只保存已经完成译码和寄存器读取的执行payload，
// 不负责译码、冒险判断或执行；这些职责分别属于IDU、hazard controller和EXU。
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

    // 冒险控制只需要下面三个窄状态，不应从execute_packet_valid和宽uop重新组合译码。
    // 它们与主槽payload在同一时钟沿更新，分别表示当前EX指令产生的结果能否立即前递、
    // 是否必须等待后级结果，以及当前指令是否要求流水线串行化。
    output logic execute_forwardable_producer_present_o,
    output logic execute_blocking_producer_present_o,
    output logic execute_serializing_instruction_present_o,

    // flush只删除尚未产生架构副作用的年轻指令。当前输出仍可在本周期被EXU消费，
    // 因而EX级产生redirect的分支自身能够进入WB，下一拍stage中只留下bubble。
    input logic flush_i
);

  // 主寄存器直接驱动EX；skid寄存器只在EX突然反压时保存同拍已经被ID接收的下一条
  // 指令。上游ready只依赖本级skid valid，不再组合穿过EX、LSU、D-cache和WB。
  // 下游连续ready时，主寄存器每拍用新payload替换已消费payload，吞吐仍为1条/拍。
  execute_packet_t execute_packet_q;
  execute_packet_t skid_execute_packet_q;
  logic            execute_packet_valid_q;
  logic            skid_execute_packet_valid_q;
  logic            execute_forwardable_producer_present_q;
  logic            execute_blocking_producer_present_q;
  logic            execute_serializing_instruction_present_q;
  logic            skid_forwardable_producer_present_q;
  logic            skid_blocking_producer_present_q;
  logic            skid_serializing_instruction_present_q;
  logic            input_producer_present;
  logic            input_forwardable_producer_present;
  logic            input_blocking_producer_present;
  logic            input_serializing_instruction_present;
  logic            input_handshake;
  logic            output_handshake;

  // ready只描述本级是否有物理槽位，不能再混入flush。flush负责在时钟沿清除valid；
  // 同拍采样到的错误路径payload不会获得valid，因此不会被EXU解释或产生副作用。
  // 这种分离避免恢复信号穿过ready网络后控制整个宽payload寄存器的写入选择。
  assign decoded_execute_packet_ready_o = !skid_execute_packet_valid_q;
  assign execute_packet_o               = execute_packet_q;
  assign execute_packet_valid_o         = execute_packet_valid_q;
  assign execute_forwardable_producer_present_o =
      execute_forwardable_producer_present_q;
  assign execute_blocking_producer_present_o = execute_blocking_producer_present_q;
  assign execute_serializing_instruction_present_o =
      execute_serializing_instruction_present_q;
  assign input_handshake                 = decoded_execute_packet_valid_i &&
                                           decoded_execute_packet_ready_o;
  assign output_handshake                = execute_packet_valid_q && execute_packet_ready_i;

  assign input_producer_present = decoded_execute_packet_valid_i &&
                                  decoded_execute_packet_i.uop.writes_rd &&
                                  (decoded_execute_packet_i.uop.rd != arch_reg_idx_t'(0));
  // CSR在IDU中已串行化，年轻消费者只能在它提交后进入，因而无需EX即时前递。
  // 把CSR统一作为等待完成的生产者，避免CSR地址合法性判断串到本级生产者状态D端。
  // CSR读值和illegal仍随payload寄存，由EXU精确处理正常写回或非法指令异常。
  assign input_forwardable_producer_present = input_producer_present &&
      !decoded_execute_packet_i.uop.exception_valid &&
      ((decoded_execute_packet_i.uop.fu_type == FU_INT) ||
       (decoded_execute_packet_i.uop.fu_type == FU_BRANCH));
  assign input_blocking_producer_present = input_producer_present &&
                                           !input_forwardable_producer_present;
  assign input_serializing_instruction_present = decoded_execute_packet_valid_i &&
                                                  decoded_execute_packet_i.uop.serializing;

  // payload没有架构有效性，也无需复位或flush。物理数据采样只由本级主槽、skid槽和
  // 下游消费状态决定，不使用input_handshake。这样flush以及上游valid不会进入宽payload
  // 的时钟门控和写入mux；没有对应valid的物理写入不具备任何流水线语义。
  always_ff @(posedge clk_i) begin
    if (output_handshake) begin
      if (skid_execute_packet_valid_q) begin
        execute_packet_q <= skid_execute_packet_q;
      end else begin
        execute_packet_q <= decoded_execute_packet_i;
      end
    end else if (!execute_packet_valid_q) begin
      execute_packet_q <= decoded_execute_packet_i;
    end else if (!skid_execute_packet_valid_q) begin
      skid_execute_packet_q <= decoded_execute_packet_i;
    end
  end

  // valid位单独承载流水级状态。flush优先级最高，保证错误路径payload即使物理上仍留在
  // 数据寄存器中，也绝不会被EXU解释为有效指令。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      execute_packet_valid_q      <= 1'b0;
      skid_execute_packet_valid_q <= 1'b0;
      execute_forwardable_producer_present_q  <= 1'b0;
      execute_blocking_producer_present_q     <= 1'b0;
      execute_serializing_instruction_present_q <= 1'b0;
      skid_forwardable_producer_present_q     <= 1'b0;
      skid_blocking_producer_present_q        <= 1'b0;
      skid_serializing_instruction_present_q  <= 1'b0;
    end else if (flush_i) begin
      execute_packet_valid_q      <= 1'b0;
      skid_execute_packet_valid_q <= 1'b0;
      execute_forwardable_producer_present_q  <= 1'b0;
      execute_blocking_producer_present_q     <= 1'b0;
      execute_serializing_instruction_present_q <= 1'b0;
      skid_forwardable_producer_present_q     <= 1'b0;
      skid_blocking_producer_present_q        <= 1'b0;
      skid_serializing_instruction_present_q  <= 1'b0;
    end else if (output_handshake) begin
      if (skid_execute_packet_valid_q) begin
        execute_packet_valid_q      <= 1'b1;
        skid_execute_packet_valid_q <= 1'b0;
        execute_forwardable_producer_present_q <=
            skid_forwardable_producer_present_q;
        execute_blocking_producer_present_q <= skid_blocking_producer_present_q;
        execute_serializing_instruction_present_q <=
            skid_serializing_instruction_present_q;
        skid_forwardable_producer_present_q    <= 1'b0;
        skid_blocking_producer_present_q       <= 1'b0;
        skid_serializing_instruction_present_q <= 1'b0;
      end else if (input_handshake) begin
        execute_packet_valid_q <= 1'b1;
        execute_forwardable_producer_present_q <= input_forwardable_producer_present;
        execute_blocking_producer_present_q    <= input_blocking_producer_present;
        execute_serializing_instruction_present_q <=
            input_serializing_instruction_present;
      end else begin
        execute_packet_valid_q <= 1'b0;
        execute_forwardable_producer_present_q  <= 1'b0;
        execute_blocking_producer_present_q     <= 1'b0;
        execute_serializing_instruction_present_q <= 1'b0;
      end
    end else if (input_handshake) begin
      if (!execute_packet_valid_q) begin
        execute_packet_valid_q <= 1'b1;
        execute_forwardable_producer_present_q <= input_forwardable_producer_present;
        execute_blocking_producer_present_q    <= input_blocking_producer_present;
        execute_serializing_instruction_present_q <=
            input_serializing_instruction_present;
      end else begin
        skid_execute_packet_valid_q <= 1'b1;
        skid_forwardable_producer_present_q <= input_forwardable_producer_present;
        skid_blocking_producer_present_q    <= input_blocking_producer_present;
        skid_serializing_instruction_present_q <=
            input_serializing_instruction_present;
      end
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (execute_packet_valid_o && !execute_packet_ready_i && !flush_i)
    |=> (execute_packet_valid_o && $stable(execute_packet_o)))
  else $error("ID/EX stage changed payload while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni) flush_i |=> !execute_packet_valid_o)
  else $error("ID/EX stage retained a flushed instruction");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    skid_execute_packet_valid_q |-> execute_packet_valid_q)
  else $error("ID/EX skid entry became valid without a primary entry");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    $onehot0({execute_forwardable_producer_present_o,
              execute_blocking_producer_present_o}))
  else $error("ID/EX marked one producer as both forwardable and blocking");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (execute_forwardable_producer_present_o || execute_blocking_producer_present_o ||
     execute_serializing_instruction_present_o) |-> execute_packet_valid_o)
  else $error("ID/EX timing metadata remained present without a valid execute packet");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
