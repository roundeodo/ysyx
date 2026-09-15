// AXI4默认错误target。未映射请求不能被静默丢弃：读事务按ARLEN返回完整
// DECERR burst，写事务接收AW和全部W beat后返回一次带原始BID的DECERR。
module riscv32_axi4_error_target
  import riscv32_axi4_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  axi4_manager_to_target_t axi_target_i,
    output axi4_target_to_manager_t axi_target_o
);

  // error target必须原样保存并返回事务ID，因此ID宽度来自全局AXI fabric配置。
  // 不要修改AXI4_RESP_DECERR等协议枚举名称。

  logic read_transaction_present_q;
  logic read_transaction_present_d;
  logic [MEM_AXI_ID_WIDTH-1:0] read_transaction_id_q;
  logic [MEM_AXI_ID_WIDTH-1:0] read_transaction_id_d;
  logic [8:0] read_beat_count_q;
  logic [8:0] read_beat_count_d;

  logic write_address_present_q;
  logic write_address_present_d;
  logic [MEM_AXI_ID_WIDTH-1:0] write_transaction_id_q;
  logic [MEM_AXI_ID_WIDTH-1:0] write_transaction_id_d;
  logic write_last_data_present_q;
  logic write_last_data_present_d;

  logic read_address_handshake;
  logic read_data_handshake;
  logic write_address_handshake;
  logic write_data_handshake;
  logic write_response_handshake;

  assign read_address_handshake = axi_target_i.ar_valid && axi_target_o.ar_ready;
  assign read_data_handshake = axi_target_o.r_valid && axi_target_i.r_ready;
  assign write_address_handshake = axi_target_i.aw_valid && axi_target_o.aw_ready;
  assign write_data_handshake = axi_target_i.w_valid && axi_target_o.w_ready;
  assign write_response_handshake = axi_target_o.b_valid && axi_target_i.b_ready;

  // 第一段：读写通道互相独立。写数据允许早于写地址到达，因为错误target无需
  // 地址即可丢弃数据，但仍必须等AW与WLAST都出现后才能产生B响应。
  always_comb begin
    axi_target_o = '0;

    axi_target_o.ar_ready = !read_transaction_present_q;
    axi_target_o.r.data   = '0;
    axi_target_o.r.id     = read_transaction_id_q;
    axi_target_o.r.resp   = AXI4_RESP_DECERR;
    axi_target_o.r.last   = read_beat_count_q == 9'd1;
    axi_target_o.r_valid  = read_transaction_present_q;

    axi_target_o.aw_ready = !write_address_present_q;
    axi_target_o.w_ready  = !write_last_data_present_q;
    axi_target_o.b.id     = write_transaction_id_q;
    axi_target_o.b.resp   = AXI4_RESP_DECERR;
    axi_target_o.b_valid  = write_address_present_q && write_last_data_present_q;
  end

  // 第二段：读侧按LEN+1生成beat；写侧分别记录AW和WLAST是否已经发生。
  always_comb begin
    read_transaction_present_d = read_transaction_present_q;
    read_transaction_id_d      = read_transaction_id_q;
    read_beat_count_d           = read_beat_count_q;
    write_address_present_d     = write_address_present_q;
    write_transaction_id_d      = write_transaction_id_q;
    write_last_data_present_d   = write_last_data_present_q;

    if (read_address_handshake) begin
      read_transaction_present_d = 1'b1;
      read_transaction_id_d      = axi_target_i.ar.id;
      read_beat_count_d           = {1'b0, axi_target_i.ar.len} + 9'd1;
    end

    if (read_data_handshake) begin
      if (read_beat_count_q == 9'd1) begin
        read_transaction_present_d = 1'b0;
        read_beat_count_d           = '0;
      end else begin
        read_beat_count_d = read_beat_count_q - 9'd1;
      end
    end

    if (write_address_handshake) begin
      write_address_present_d = 1'b1;
      write_transaction_id_d  = axi_target_i.aw.id;
    end

    if (write_data_handshake && axi_target_i.w.last) begin
      write_last_data_present_d = 1'b1;
    end

    if (write_response_handshake) begin
      write_address_present_d   = 1'b0;
      write_transaction_id_d    = '0;
      write_last_data_present_d = 1'b0;
    end
  end

  // 第三段：读事务、写地址和写数据完成状态分别更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_transaction_present_q <= 1'b0;
      read_transaction_id_q      <= '0;
      read_beat_count_q           <= '0;
    end else begin
      read_transaction_present_q <= read_transaction_present_d;
      read_transaction_id_q      <= read_transaction_id_d;
      read_beat_count_q           <= read_beat_count_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_address_present_q   <= 1'b0;
      write_transaction_id_q    <= '0;
      write_last_data_present_q <= 1'b0;
    end else begin
      write_address_present_q   <= write_address_present_d;
      write_transaction_id_q    <= write_transaction_id_d;
      write_last_data_present_q <= write_last_data_present_d;
    end
  end

endmodule
