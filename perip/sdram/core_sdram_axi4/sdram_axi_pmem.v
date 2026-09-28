//-----------------------------------------------------------------
//                    SDRAM Controller (AXI4)
//                           V1.0
//                     Ultra-Embedded.com
//                     Copyright 2015-2019
//
//                 Email: admin@ultra-embedded.com
//
//                         License: GPL
// If you would like a version with a more permissive license for
// use in closed source commercial applications please contact me
// for details.
//-----------------------------------------------------------------
//
// This file is open source HDL; you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation; either version 2 of
// the License, or (at your option) any later version.
//
// This file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public
// License along with this file; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
// USA
//-----------------------------------------------------------------

//-----------------------------------------------------------------
//                          Generated File
//-----------------------------------------------------------------

`ifndef YSYX_SDRAM_NATIVE_READ_BURST
`define YSYX_SDRAM_NATIVE_READ_BURST 1
`endif

module sdram_axi_pmem
(
    // Inputs
     input           clk_i
    ,input           rst_i
    ,input           axi_awvalid_i
    ,input  [ 31:0]  axi_awaddr_i
    ,input  [  3:0]  axi_awid_i
    ,input  [  7:0]  axi_awlen_i
    ,input  [  2:0]  axi_awsize_i
    ,input  [  1:0]  axi_awburst_i
    ,input           axi_wvalid_i
    ,input  [ 31:0]  axi_wdata_i
    ,input  [  3:0]  axi_wstrb_i
    ,input           axi_wlast_i
    ,input           axi_bready_i
    ,input           axi_arvalid_i
    ,input  [ 31:0]  axi_araddr_i
    ,input  [  3:0]  axi_arid_i
    ,input  [  7:0]  axi_arlen_i
    ,input  [  2:0]  axi_arsize_i
    ,input  [  1:0]  axi_arburst_i
    ,input           axi_rready_i
    ,input           ram_accept_i
    ,input           ram_ack_i
    ,input           ram_error_i
    ,input  [ 31:0]  ram_read_data_i

    // Outputs
    ,output          axi_awready_o
    ,output          axi_wready_o
    ,output          axi_bvalid_o
    ,output [  1:0]  axi_bresp_o
    ,output [  3:0]  axi_bid_o
    ,output          axi_arready_o
    ,output          axi_rvalid_o
    ,output [ 31:0]  axi_rdata_o
    ,output [  1:0]  axi_rresp_o
    ,output [  3:0]  axi_rid_o
    ,output          axi_rlast_o
    ,output [  3:0]  ram_wr_o
    ,output          ram_rd_o
    ,output [  7:0]  ram_len_o
    ,output [ 31:0]  ram_addr_o
    ,output [ 31:0]  ram_write_data_o
);



//-------------------------------------------------------------
// calculate_addr_next
//-------------------------------------------------------------
function [31:0] calculate_addr_next;
    input [31:0] addr;
    input [1:0]  axtype;
    input [7:0]  axlen;
    input [2:0]  axsize;

    reg [31:0]   mask;
    reg [31:0]   beat_bytes;
    reg [31:0]   burst_bytes;
begin
    beat_bytes  = 32'd1 << axsize;
    burst_bytes = beat_bytes * ({{24{1'b0}}, axlen} + 32'd1);
    mask        = burst_bytes - 32'd1;

    case (axtype)
    2'd0: // AXI4_BURST_FIXED
    begin
        calculate_addr_next = addr;
    end
    2'd2: // AXI4_BURST_WRAP
    begin
        calculate_addr_next = (addr & ~mask) | ((addr + beat_bytes) & mask);
    end
    default: // AXI4_BURST_INCR
        calculate_addr_next = addr + beat_bytes;
    endcase
end
endfunction

//-----------------------------------------------------------------
// Registers / Wires
//-----------------------------------------------------------------
localparam AXI_BURST_INCR             = 2'd1;
localparam SDRAM_NATIVE_BL8_BEATS     = 4'd8;
localparam RESPONSE_FIFO_DEPTH        = 16;

reg [7:0]   req_len_q;
reg [31:0]  req_addr_q;
reg         req_rd_q;
reg         req_wr_q;
reg [3:0]   req_id_q;
reg [1:0]   req_axburst_q;
reg [7:0]   req_axlen_q;
reg [2:0]   req_axsize_q;
reg         req_prio_q;
reg         req_hold_rd_q;
reg         req_hold_wr_q;

// 一个AXI读事务可以被拆成多个不跨32B边界的物理SDRAM连续读段。事务级状态
// 负责保持AXI ID和RLAST语义；物理段状态负责记录每段实际返回的beat数量。
reg         segmented_read_transaction_active_q;
reg [3:0]   segmented_read_transaction_id_q;
reg [8:0]   segmented_read_transaction_total_beat_count_q;
reg [8:0]   segmented_read_transaction_response_beat_index_q;
reg [8:0]   segmented_read_unissued_beat_count_q;
reg [31:0]  segmented_read_next_segment_addr_q;
reg         segmented_read_segment_request_pending_q;
reg [3:0]   segmented_read_physical_response_beat_count_q;

wire        req_fifo_accept_w;
wire [2:0]  req_fifo_count_w;
wire        req_out_valid_w;
wire [5:0]  req_out_w;
wire        response_fifo_accept_w;
wire [4:0]  response_fifo_count_w;
wire        resp_valid_w;
wire        resp_accept_w;

wire [8:0] incoming_read_transaction_beat_count_w =
    {1'b0, axi_arlen_i} + 9'd1;

// 多beat、32-bit、word对齐的INCR读可以直接利用SDRAM连续读。单beat、FIXED、
// WRAP、窄传输和非word对齐事务继续使用普通路径。
wire incoming_read_transaction_uses_segmenter_w =
    (`YSYX_SDRAM_NATIVE_READ_BURST != 0) &&
    axi_arvalid_i &&
    axi_arsize_i  == 3'd2 &&
    axi_arburst_i == AXI_BURST_INCR &&
    axi_arlen_i   != 8'd0 &&
    axi_araddr_i[1:0] == 2'b00;

wire segmented_read_transaction_can_start_w =
    incoming_read_transaction_uses_segmenter_w &&
    !segmented_read_transaction_active_q &&
    !segmented_read_segment_request_pending_q &&
    segmented_read_physical_response_beat_count_q == 4'd0 &&
    !req_rd_q &&
    !req_wr_q &&
    req_fifo_count_w == 3'd0 &&
    !resp_valid_w;

wire segmented_read_continuation_can_start_w =
    segmented_read_transaction_active_q &&
    segmented_read_segment_request_pending_q &&
    segmented_read_physical_response_beat_count_q == 4'd0;

wire segmented_read_first_segment_selected_w =
    segmented_read_transaction_can_start_w;
wire segmented_read_continuation_selected_w =
    segmented_read_continuation_can_start_w;
wire segmented_read_segment_selected_w =
    segmented_read_first_segment_selected_w ||
    segmented_read_continuation_selected_w;

wire [31:0] segmented_read_segment_addr_w =
    segmented_read_continuation_selected_w ?
        segmented_read_next_segment_addr_q : axi_araddr_i;
wire [8:0] segmented_read_segment_remaining_beat_count_w =
    segmented_read_continuation_selected_w ?
        segmented_read_unissued_beat_count_q : incoming_read_transaction_beat_count_w;

// Mode Register配置为BL8，因此物理READ会在当前8-word边界内回绕。每个物理段
// 取“事务剩余beat、到下一个32B边界的beat、8”三者的最小值，从而既利用连续
// 数据阶段，又不会把回绕后的数据错误地当成AXI INCR的下一个地址。
wire [3:0] segmented_read_beat_count_before_32b_boundary_w =
    SDRAM_NATIVE_BL8_BEATS - {1'b0, segmented_read_segment_addr_w[4:2]};
wire [3:0] segmented_read_remaining_beat_count_limited_w =
    segmented_read_segment_remaining_beat_count_w >= 9'd8 ?
        SDRAM_NATIVE_BL8_BEATS : segmented_read_segment_remaining_beat_count_w[3:0];
wire [3:0] segmented_read_segment_beat_count_w =
    segmented_read_remaining_beat_count_limited_w <
    segmented_read_beat_count_before_32b_boundary_w ?
        segmented_read_remaining_beat_count_limited_w :
        segmented_read_beat_count_before_32b_boundary_w;

// 一条物理SDRAM burst不能被RREADY暂停。发命令前必须为该段的全部返回beat
// 预留FIFO空间；上一段全部到达后才允许发下一段，因此这里不需要额外预约计数器。
wire [5:0] response_fifo_count_after_segment_w =
    {1'b0, response_fifo_count_w} + {2'b00, segmented_read_segment_beat_count_w};
wire segmented_read_segment_has_fifo_space_w =
    response_fifo_accept_w &&
    response_fifo_count_after_segment_w <= RESPONSE_FIFO_DEPTH;

// Round robin priority between ordinary read and write requests. Once a
// segmented transaction starts, its continuation owns the physical read port
// until every segment has been issued; AXI responses may still drain in parallel.
wire write_prio_w   = ((req_prio_q  & !req_hold_rd_q) | req_hold_wr_q);
wire read_prio_w    = ((!req_prio_q & !req_hold_wr_q) | req_hold_rd_q);

wire write_active_w =
    !segmented_read_transaction_active_q &&
    (axi_awvalid_i || req_wr_q) && !req_rd_q && req_fifo_accept_w &&
    (write_prio_w || req_wr_q || !axi_arvalid_i);

wire segmented_read_first_segment_active_w =
    segmented_read_first_segment_selected_w &&
    segmented_read_segment_has_fifo_space_w &&
    (read_prio_w || !axi_awvalid_i);
wire segmented_read_continuation_active_w =
    segmented_read_continuation_selected_w &&
    segmented_read_segment_has_fifo_space_w;
wire segmented_read_segment_active_w =
    segmented_read_first_segment_active_w || segmented_read_continuation_active_w;

wire ordinary_read_active_w =
    !segmented_read_transaction_active_q &&
    // 命中分段条件的AXI burst若暂时没有足够FIFO空间，必须通过ARREADY反压等待。
    // 不能把它降级为普通首beat，否则req_rd_q会按分段事务保持为0，事务将只返回
    // 一个非末beat并永久等待RLAST。已经登记的普通burst continuation不受此限制。
    (req_rd_q || !incoming_read_transaction_uses_segmenter_w) &&
    (axi_arvalid_i || req_rd_q) && !req_wr_q && req_fifo_accept_w &&
    (read_prio_w || req_rd_q || !axi_awvalid_i);
wire read_active_w = segmented_read_segment_active_w || ordinary_read_active_w;

assign axi_awready_o = write_active_w && !req_wr_q && ram_accept_i && req_fifo_accept_w;
assign axi_wready_o  = write_active_w &&              ram_accept_i && req_fifo_accept_w;
assign axi_arready_o = !segmented_read_transaction_active_q &&
                       read_active_w && !req_rd_q && ram_accept_i &&
                       (segmented_read_first_segment_active_w || req_fifo_accept_w);

wire [31:0] addr_w = segmented_read_continuation_active_w ?
                     segmented_read_next_segment_addr_q :
                     ((req_wr_q || req_rd_q) ? req_addr_q :
                      write_active_w ? axi_awaddr_i : axi_araddr_i);

wire wr_w = write_active_w && axi_wvalid_i;
wire rd_w = read_active_w;

assign ram_addr_o       = addr_w;
assign ram_write_data_o = axi_wdata_i;
assign ram_rd_o         = rd_w;
assign ram_wr_o         = wr_w ? axi_wstrb_i : 4'b0;
// len保存当前物理连续读段的beat数量减一，合法范围为0..7。
assign ram_len_o        = segmented_read_segment_active_w ?
                          {4'b0000, segmented_read_segment_beat_count_w - 4'd1} : 8'd0;

wire segmented_read_segment_request_accepted_w =
    segmented_read_segment_active_w && ram_rd_o && ram_accept_i;
wire segmented_read_first_segment_request_accepted_w =
    segmented_read_first_segment_active_w && ram_rd_o && ram_accept_i;
wire ordinary_ram_request_accepted_w =
    (ram_rd_o || (ram_wr_o != 4'b0)) && ram_accept_i &&
    !segmented_read_segment_request_accepted_w;

//-----------------------------------------------------------------
// Ordinary AXI request sequencing
//-----------------------------------------------------------------
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    req_len_q     <= 8'b0;
    req_addr_q    <= 32'b0;
    req_wr_q      <= 1'b0;
    req_rd_q      <= 1'b0;
    req_id_q      <= 4'b0;
    req_axburst_q <= 2'b0;
    req_axlen_q   <= 8'b0;
    req_axsize_q  <= 3'b0;
    req_prio_q    <= 1'b0;
end
else
begin
    // Burst continuation
    if (ordinary_ram_request_accepted_w)
    begin
        if (req_len_q == 8'd0)
        begin
            req_rd_q   <= 1'b0;
            req_wr_q   <= 1'b0;
        end
        else
        begin
            req_addr_q <= calculate_addr_next(req_addr_q, req_axburst_q, req_axlen_q, req_axsize_q);
            req_len_q  <= req_len_q - 8'd1;
        end
    end

    // Write command accepted
    if (axi_awvalid_i && axi_awready_o)
    begin
        // Data ready?
        if (axi_wvalid_i && axi_wready_o)
        begin
            req_wr_q      <= !axi_wlast_i;
            req_len_q     <= axi_awlen_i - 8'd1;
            req_id_q      <= axi_awid_i;
            req_axburst_q <= axi_awburst_i;
            req_axlen_q   <= axi_awlen_i;
            req_axsize_q  <= axi_awsize_i;
            req_addr_q    <= calculate_addr_next(axi_awaddr_i, axi_awburst_i, axi_awlen_i, axi_awsize_i);
        end
        // Data not ready
        else
        begin
            req_wr_q      <= 1'b1;
            req_len_q     <= axi_awlen_i;
            req_id_q      <= axi_awid_i;
            req_axburst_q <= axi_awburst_i;
            req_axlen_q   <= axi_awlen_i;
            req_axsize_q  <= axi_awsize_i;
            req_addr_q    <= axi_awaddr_i;
        end
        req_prio_q    <= !req_prio_q;
    end
    // Read command accepted
    else if (axi_arvalid_i && axi_arready_o)
    begin
        req_rd_q      <= incoming_read_transaction_uses_segmenter_w ?
                         1'b0 : (axi_arlen_i != 0);
        req_len_q     <= axi_arlen_i - 8'd1;
        req_addr_q    <= calculate_addr_next(axi_araddr_i, axi_arburst_i, axi_arlen_i, axi_arsize_i);
        req_id_q      <= axi_arid_i;
        req_axburst_q <= axi_arburst_i;
        req_axlen_q   <= axi_arlen_i;
        req_axsize_q  <= axi_arsize_i;
        req_prio_q    <= !req_prio_q;
    end
end

//-----------------------------------------------------------------
// Segmented read transaction and physical segment tracking
//-----------------------------------------------------------------
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    segmented_read_transaction_active_q             <= 1'b0;
    segmented_read_transaction_id_q                 <= 4'b0;
    segmented_read_transaction_total_beat_count_q   <= 9'd0;
    segmented_read_transaction_response_beat_index_q <= 9'd0;
end
else
begin
    if (segmented_read_first_segment_request_accepted_w)
    begin
        segmented_read_transaction_active_q              <= 1'b1;
        segmented_read_transaction_id_q                  <= axi_arid_i;
        segmented_read_transaction_total_beat_count_q    <= incoming_read_transaction_beat_count_w;
        segmented_read_transaction_response_beat_index_q <= 9'd0;
    end
    else if (segmented_read_transaction_active_q && axi_rvalid_o && axi_rready_i)
    begin
        if (segmented_read_transaction_response_beat_index_q + 9'd1 ==
            segmented_read_transaction_total_beat_count_q)
        begin
            segmented_read_transaction_active_q              <= 1'b0;
            segmented_read_transaction_response_beat_index_q <= 9'd0;
        end
        else
            segmented_read_transaction_response_beat_index_q <=
                segmented_read_transaction_response_beat_index_q + 9'd1;
    end
end

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    segmented_read_unissued_beat_count_q          <= 9'd0;
    segmented_read_next_segment_addr_q            <= 32'd0;
    segmented_read_segment_request_pending_q      <= 1'b0;
    segmented_read_physical_response_beat_count_q <= 4'd0;
end
else
begin
    if (segmented_read_segment_request_accepted_w)
    begin
        segmented_read_unissued_beat_count_q <=
            segmented_read_segment_remaining_beat_count_w -
            {5'b00000, segmented_read_segment_beat_count_w};
        segmented_read_next_segment_addr_q <=
            segmented_read_segment_addr_w +
            ({28'd0, segmented_read_segment_beat_count_w} << 2);
        segmented_read_segment_request_pending_q <=
            segmented_read_segment_remaining_beat_count_w !=
            {5'b00000, segmented_read_segment_beat_count_w};
        segmented_read_physical_response_beat_count_q <=
            segmented_read_segment_beat_count_w;
    end
    else if (segmented_read_transaction_active_q && ram_ack_i &&
             segmented_read_physical_response_beat_count_q != 4'd0)
    begin
        segmented_read_physical_response_beat_count_q <=
            segmented_read_physical_response_beat_count_q - 4'd1;
    end

    if (segmented_read_transaction_active_q && axi_rvalid_o && axi_rready_i &&
        segmented_read_transaction_response_beat_index_q + 9'd1 ==
        segmented_read_transaction_total_beat_count_q)
    begin
        segmented_read_unissued_beat_count_q          <= 9'd0;
        segmented_read_next_segment_addr_q            <= 32'd0;
        segmented_read_segment_request_pending_q      <= 1'b0;
        segmented_read_physical_response_beat_count_q <= 4'd0;
    end
end

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    req_hold_rd_q   <= 1'b0;
    req_hold_wr_q   <= 1'b0;
end
else
begin
    if (ram_rd_o && !ram_accept_i)
        req_hold_rd_q   <= 1'b1;
    else if (ram_accept_i)
        req_hold_rd_q   <= 1'b0;

    if ((|ram_wr_o) && !ram_accept_i)
        req_hold_wr_q   <= 1'b1;
    else if (ram_accept_i)
        req_hold_wr_q   <= 1'b0;
end

//-----------------------------------------------------------------
// Request tracking
//-----------------------------------------------------------------
wire       req_push_w =
    ordinary_ram_request_accepted_w;
reg [5:0]  req_in_r;


always @ *
begin
    req_in_r = 6'b0;

    // First cycle of read burst
    if (axi_arvalid_i && axi_arready_o)
        req_in_r = {1'b1, (axi_arlen_i == 8'd0), axi_arid_i};
    // First cycle of write burst
    else if (axi_awvalid_i && axi_awready_o)
        req_in_r = {1'b0, (axi_awlen_i == 8'd0), axi_awid_i};
    // In burst
    else
        req_in_r = {ram_rd_o, (req_len_q == 8'd0), req_id_q};
end

sdram_axi_pmem_fifo2
#( .WIDTH(1 + 1 + 4) )
u_requests
(
    .clk_i(clk_i),
    .rst_i(rst_i),

    // Input
    .data_in_i(req_in_r),
    .push_i(req_push_w),
    .accept_o(req_fifo_accept_w),
    .count_o(req_fifo_count_w),

    // Output
    .pop_i(resp_accept_w),
    .data_out_o(req_out_w),
    .valid_o(req_out_valid_w)
);

wire resp_is_write_w = req_out_valid_w ? ~req_out_w[5] : 1'b0;
wire resp_is_read_w  = req_out_valid_w ? req_out_w[5]  : 1'b0;
wire resp_is_last_w  = req_out_w[4];
wire [3:0] resp_id_w = req_out_w[3:0];

//-----------------------------------------------------------------
// Response buffering
//-----------------------------------------------------------------
sdram_axi_pmem_fifo2
#( .WIDTH(32), .DEPTH(RESPONSE_FIFO_DEPTH), .ADDR_W(4) )
u_response
(
    .clk_i(clk_i),
    .rst_i(rst_i),

    // Input
    .data_in_i(ram_read_data_i),
    .push_i(ram_ack_i),
    .accept_o(response_fifo_accept_w),
    .count_o(response_fifo_count_w),

    // Output
    .pop_i(resp_accept_w),
    .data_out_o(axi_rdata_o),
    .valid_o(resp_valid_w)
);

//-----------------------------------------------------------------
// Response
//-----------------------------------------------------------------
assign axi_bvalid_o  = resp_valid_w & !segmented_read_transaction_active_q &
                       resp_is_write_w & resp_is_last_w;
assign axi_bresp_o   = 2'b0;
assign axi_bid_o     = resp_id_w;

assign axi_rvalid_o  = resp_valid_w &
                       (segmented_read_transaction_active_q || resp_is_read_w);
assign axi_rresp_o   = 2'b0;
assign axi_rid_o     = segmented_read_transaction_active_q ?
                       segmented_read_transaction_id_q : resp_id_w;
assign axi_rlast_o   = segmented_read_transaction_active_q ?
                       (segmented_read_transaction_response_beat_index_q + 9'd1 ==
                        segmented_read_transaction_total_beat_count_q) : resp_is_last_w;

assign resp_accept_w    = (axi_rvalid_o & axi_rready_i) |
                          (axi_bvalid_o & axi_bready_i) |
                          (resp_valid_w & resp_is_write_w & !resp_is_last_w); // Ignore write resps mid burst

endmodule

//-----------------------------------------------------------------
// FIFO
//-----------------------------------------------------------------
module sdram_axi_pmem_fifo2

//-----------------------------------------------------------------
// Params
//-----------------------------------------------------------------
#(
    parameter WIDTH   = 8,
    parameter DEPTH   = 4,
    parameter ADDR_W  = 2
)
//-----------------------------------------------------------------
// Ports
//-----------------------------------------------------------------
(
    // Inputs
     input               clk_i
    ,input               rst_i
    ,input  [WIDTH-1:0]  data_in_i
    ,input               push_i
    ,input               pop_i

    // Outputs
    ,output [WIDTH-1:0]  data_out_o
    ,output              accept_o
    ,output              valid_o
    ,output [ADDR_W:0]   count_o
);

//-----------------------------------------------------------------
// Local Params
//-----------------------------------------------------------------
localparam COUNT_W = ADDR_W + 1;

//-----------------------------------------------------------------
// Registers
//-----------------------------------------------------------------
reg [WIDTH-1:0]         ram [DEPTH-1:0];
reg [ADDR_W-1:0]        rd_ptr;
reg [ADDR_W-1:0]        wr_ptr;
reg [COUNT_W-1:0]       count;

//-----------------------------------------------------------------
// Sequential
//-----------------------------------------------------------------
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    count   <= {(COUNT_W) {1'b0}};
    rd_ptr  <= {(ADDR_W) {1'b0}};
    wr_ptr  <= {(ADDR_W) {1'b0}};
end
else
begin
    // Push
    if (push_i & accept_o)
    begin
        ram[wr_ptr] <= data_in_i;
        wr_ptr      <= wr_ptr + 1;
    end

    // Pop
    if (pop_i & valid_o)
        rd_ptr      <= rd_ptr + 1;

    // Count up
    if ((push_i & accept_o) & ~(pop_i & valid_o))
        count <= count + 1;
    // Count down
    else if (~(push_i & accept_o) & (pop_i & valid_o))
        count <= count - 1;
end

//-------------------------------------------------------------------
// Combinatorial
//-------------------------------------------------------------------
/* verilator lint_off WIDTH */
assign accept_o   = (count != DEPTH);
assign valid_o    = (count != 0);
/* verilator lint_on WIDTH */

assign data_out_o = ram[rd_ptr];
assign count_o    = count;



endmodule
