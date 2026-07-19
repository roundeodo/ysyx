module riscv32_lsu
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  lsu_req_t lsu_req_i,
    input  logic     lsu_req_valid_i,
    output logic     lsu_req_ready_o,

    output writeback_result_t lsu_writeback_o,
    output logic              lsu_writeback_valid_o,
    input  logic              lsu_writeback_ready_i,

    output axi_lite_addr_t lsu_axi_ar_o,
    output logic           lsu_axi_arvalid_o,
    input  logic           lsu_axi_arready_i,

    input  axi_lite_r_t lsu_axi_r_i,
    input  logic        lsu_axi_rvalid_i,
    output logic        lsu_axi_rready_o,

    output axi_lite_addr_t lsu_axi_aw_o,
    output logic           lsu_axi_awvalid_o,
    input  logic           lsu_axi_awready_i,

    output axi_lite_w_t lsu_axi_w_o,
    output logic        lsu_axi_wvalid_o,
    input  logic        lsu_axi_wready_i,

    input  axi_lite_b_t lsu_axi_b_i,
    input  logic        lsu_axi_bvalid_i,
    output logic        lsu_axi_bready_o
    // AR/AW/W的VALID和payload由LSU产生，R/B的READY也由LSU产生。不要保留cmd/size作为
    // AXI信号：Lite没有读写cmd，也没有AxSIZE；读写方向由使用AR还是AW/W表示。
);

  // LSU只负责形成访存请求、格式化响应和报告完成。DPI、SRAM、MMIO与未来D-cache
  // 都属于dmem通道另一侧，不能在本模块中直接访问。

  // store的AW与W必须在同一状态并行尝试，但分别记录当前事务此前是否已经完成握手。
  // 不能写成“先等AW握手，再拉WVALID”，否则虽然可能工作，却损失并行性，并容易与某些
  // 等待WVALID才给AWREADY的slave形成死锁。只有两个通道都完成握手后才能进入WAIT_B。
  typedef enum logic [2:0] {
    LSU_IDLE,
    LSU_SEND_AR,
    LSU_WAIT_R,
    LSU_SEND_AW_W,
    LSU_WAIT_B,
    LSU_HOLD_WRITEBACK
  } lsu_state_e;

  lsu_state_e                         state_q;
  lsu_state_e                         state_d;

  // lsu_req_q保存已经从EXU取得所有权的操作。请求握手后，response格式化只能读取它，
  // 不能再读取可能已经变化的lsu_req_i。
  lsu_req_t                           lsu_req_q;
  lsu_req_t                           lsu_req_d;
  lsu_req_t                           active_lsu_req;

  // writeback_q只在completion mux反压时使用；无反压响应直接旁路到writeback端口。
  writeback_result_t                  writeback_q;
  writeback_result_t                  writeback_d;
  writeback_result_t                  no_dmem_writeback;
  writeback_result_t                  dmem_writeback;

  // done位表示本store的对应channel已经交给slave。AW握手不能清掉WVALID，W握手也不能
  // 清掉AWVALID。每次接收新store时两个done清零；各自握手时独立置1；B握手完成后清零。
  // 基线只允许一个CPU访存，因此不需要AXI ID，也不需要地址/数据队列。

  axi_lite_addr_t                     ar_payload;
  axi_lite_addr_t                     aw_payload;

  axi_lite_w_t                        w_payload;
  logic                               lsu_req_handshake;
  logic                               lsu_writeback_handshake;
  logic                               ar_handshake;
  logic                               r_handshake;
  logic                               aw_handshake;
  logic                               w_handshake;
  logic                               b_handshake;

  logic                               aw_handshake_occurred_q;
  logic                               aw_handshake_occurred_d;

  logic                               w_handshake_occurred_q;
  logic                               w_handshake_occurred_d;



  logic                               is_load;
  logic                               is_store;
  logic                               has_dmem_access;
  logic                               is_halfword_access;
  logic                               is_word_access;
  logic                               misaligned;
  logic                               complete_without_dmem;
  logic              [           1:0] byte_offset;
  logic              [      XLEN-1:0] store_wdata;
  logic              [BYTE_LANES-1:0] store_wmask;
  logic              [           7:0] selected_byte;
  logic              [          15:0] selected_halfword;
  logic              [      XLEN-1:0] formatted_load_data;

  assign lsu_req_handshake       = lsu_req_valid_i && lsu_req_ready_o;
  assign lsu_writeback_handshake = lsu_writeback_valid_o && lsu_writeback_ready_i;
  assign ar_handshake            = lsu_axi_arvalid_o && lsu_axi_arready_i;
  assign r_handshake             = lsu_axi_rvalid_i && lsu_axi_rready_o;
  assign aw_handshake            = lsu_axi_awvalid_o && lsu_axi_awready_i;
  assign w_handshake             = lsu_axi_wvalid_o && lsu_axi_wready_i;
  assign b_handshake             = lsu_axi_bvalid_i && lsu_axi_bready_o;



  // Interpret the active request and place store bytes into AXI data lanes.
  always_comb begin
    active_lsu_req = (state_q == LSU_IDLE) ? lsu_req_i : lsu_req_q;

    byte_offset           = active_lsu_req.effective_addr[1:0];
    is_load               = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
    is_store              = active_lsu_req.uop.mem_ctrl.cmd == MEM_CMD_STORE;
    has_dmem_access       = is_load || is_store;
    is_halfword_access    = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_HALF;
    is_word_access        = active_lsu_req.uop.mem_ctrl.size == MEM_SIZE_WORD;
    misaligned            = has_dmem_access && ((is_halfword_access && byte_offset[0]) || (is_word_access && (byte_offset != 2'b00)));
    complete_without_dmem = active_lsu_req.uop.exception_valid || misaligned || !has_dmem_access;

    store_wdata = '0;
    store_wmask = '0;

    unique case (active_lsu_req.uop.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        store_wmask = 4'b0001 << byte_offset;
        store_wdata = {24'b0, active_lsu_req.store_data[7:0]} << {byte_offset, 3'b000};
      end

      MEM_SIZE_HALF: begin
        store_wmask = 4'b0011 << byte_offset;
        store_wdata = {16'b0, active_lsu_req.store_data[15:0]} << {byte_offset, 3'b000};
      end

      MEM_SIZE_WORD: begin
        store_wmask = 4'b1111;
        store_wdata = active_lsu_req.store_data;
      end
    endcase
  end


  // AXI4-Lite has no AxSIZE. Read a full aligned word and select load lanes locally;
  // use WSTRB to restrict byte and halfword stores.
  localparam int unsigned AXI_ADDR_LSB = $clog2(BYTE_LANES);

  always_comb begin
    ar_payload      = '0;
    ar_payload.addr = {active_lsu_req.effective_addr[XLEN-1:AXI_ADDR_LSB], {AXI_ADDR_LSB{1'b0}}};
    ar_payload.prot = 3'b001;
  end

  always_comb begin
    aw_payload      = '0;
    aw_payload.addr = {active_lsu_req.effective_addr[XLEN-1:AXI_ADDR_LSB], {AXI_ADDR_LSB{1'b0}}};
    aw_payload.prot = 3'b001;
  end

  always_comb begin
    w_payload      = '0;
    w_payload.data = store_wdata;
    w_payload.strb = store_wmask;
  end



  // Select the addressed lane from the full-width AXI read response.
  always_comb begin
    selected_byte       = 8'(lsu_axi_r_i.data >> ({lsu_req_q.effective_addr[1:0], 3'b000}));
    selected_halfword   = 16'(lsu_axi_r_i.data >> ({lsu_req_q.effective_addr[1:0], 3'b000}));
    formatted_load_data = '0;

    unique case (lsu_req_q.uop.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        formatted_load_data = lsu_req_q.uop.mem_ctrl.unsigned_load? {24'b0,selected_byte} : {{24{selected_byte[7]}}, selected_byte};
      end
      MEM_SIZE_HALF: begin
        formatted_load_data = lsu_req_q.uop.mem_ctrl.unsigned_load? {16'b0,selected_halfword} : {{16{selected_halfword[15]}}, selected_halfword};
      end
      MEM_SIZE_WORD: begin
        formatted_load_data = lsu_axi_r_i.data;
      end
      default: ;
    endcase
  end



  // Complete pre-existing exceptions, misaligned accesses, and MEM_CMD_NONE locally.
  always_comb begin
    no_dmem_writeback     = 'd0;
    no_dmem_writeback.uop = active_lsu_req.uop;

    no_dmem_writeback.result  = '0;
    no_dmem_writeback.next_pc = active_lsu_req.next_pc;

    no_dmem_writeback.csr_wdata   = '0;
    no_dmem_writeback.memory_addr = active_lsu_req.effective_addr;

    no_dmem_writeback.memory_rdata = '0;
    no_dmem_writeback.memory_wdata = is_store ? store_wdata : '0;

    no_dmem_writeback.memory_wmask = is_store ? store_wmask : '0;

    if (!active_lsu_req.uop.exception_valid && misaligned) begin
      no_dmem_writeback.uop.exception_valid = 1'b1;

      no_dmem_writeback.uop.exception_cause = is_load? EXC_LOAD_ADDR_MISALIGNED : EXC_STORE_ADDR_MISALIGNED;

      no_dmem_writeback.uop.exception_tval = active_lsu_req.effective_addr;
    end
  end


  // Convert RRESP/BRESP failures into the matching architectural access fault.
  always_comb begin
    dmem_writeback     = '0;  // 默认清空LSU不负责的CSR等字段。
    dmem_writeback.uop = lsu_req_q.uop;
    // 恢复发请求时保存的指令身份和控制信息。
    dmem_writeback.result       = is_load ? formatted_load_data : '0;
    // load写回扩展后的数据，store不写GPR结果。
    dmem_writeback.next_pc      = lsu_req_q.next_pc;
    // 继续传递该指令的控制流元数据。
    dmem_writeback.csr_wdata   = '0;  // LSU不产生CSR写数据。
    dmem_writeback.memory_addr = lsu_req_q.effective_addr;
    // trace/commit记录原始有效地址。
    dmem_writeback.memory_rdata = is_load ? formatted_load_data : '0;
    // 记录架构可见的load值，而不是未选择lane的原始总线值。
    dmem_writeback.memory_wdata = is_store ? store_wdata : '0;
    dmem_writeback.memory_wmask = is_store ? store_wmask : '0;
    // store记录实际发送给memory的lane数据和byte mask。

    if (is_load && (lsu_axi_r_i.resp != AXI_RESP_OKAY)) begin
      dmem_writeback.uop.exception_valid = 1'b1;
      dmem_writeback.uop.exception_cause = EXC_LOAD_ACCESS_FAULT;
      dmem_writeback.uop.exception_tval  = lsu_req_q.effective_addr;
      dmem_writeback.result              = '0;
      dmem_writeback.memory_rdata        = '0;
    end else if (is_store && (lsu_axi_b_i.resp != AXI_RESP_OKAY)) begin
      dmem_writeback.uop.exception_valid = 1'b1;
      dmem_writeback.uop.exception_cause = EXC_STORE_ACCESS_FAULT;
      dmem_writeback.uop.exception_tval  = lsu_req_q.effective_addr;
    end
  end



  // Drive each source VALID independently of its matching READY.
  always_comb begin
    lsu_req_ready_o       = 1'b0;  // 默认不接收新的EXU请求。

    lsu_axi_arvalid_o = 1'b0;  // 只有IDLE真实访存或SEND_AR才能发请求。
    lsu_axi_ar_o      = '0;

    lsu_axi_rready_o      = 1'b0;

    lsu_axi_awvalid_o = 1'b0;
    lsu_axi_aw_o      = '0;

    lsu_axi_wvalid_o = 1'b0;
    lsu_axi_w_o      = '0;

    lsu_axi_bready_o      = 1'b0;

    lsu_writeback_o       = writeback_q;
    lsu_writeback_valid_o = 1'b0;  // 只有本地完成、响应旁路或HOLD才有完成结果。

    if (rst_ni) begin
      // Moore out
      unique case (state_q)
        LSU_IDLE: begin
          lsu_req_ready_o = 1'b1;

          if (lsu_req_valid_i) begin
            if (complete_without_dmem) begin
              lsu_writeback_o       = no_dmem_writeback;
              lsu_writeback_valid_o = 1'b1;
            end else if (is_load) begin
              lsu_axi_arvalid_o = 1'b1;
              lsu_axi_ar_o      = ar_payload;
            end else if (is_store) begin
              lsu_axi_awvalid_o = 1'b1;
              lsu_axi_aw_o      = aw_payload;
              lsu_axi_wvalid_o  = 1'b1;
              lsu_axi_w_o       = w_payload;
            end
          end
        end

        LSU_SEND_AR: begin
          lsu_axi_arvalid_o = 1'b1;
          lsu_axi_ar_o      = ar_payload;
        end

        LSU_SEND_AW_W: begin
          lsu_axi_awvalid_o = !aw_handshake_occurred_q;
          lsu_axi_aw_o      = aw_payload;
          lsu_axi_wvalid_o  = !w_handshake_occurred_q;
          lsu_axi_w_o       = w_payload;
        end

        LSU_WAIT_R: begin
          lsu_axi_rready_o      = 1'b1;
          lsu_writeback_valid_o = lsu_axi_rvalid_i;
          lsu_writeback_o       = dmem_writeback;
        end

        LSU_WAIT_B: begin
          lsu_axi_bready_o      = 1'b1;
          lsu_writeback_valid_o = lsu_axi_bvalid_i;
          lsu_writeback_o       = dmem_writeback;
        end

        LSU_HOLD_WRITEBACK: begin
          lsu_writeback_valid_o = 1'b1;
          lsu_writeback_o       = writeback_q;
        end

        default: begin

        end
      endcase
    end
  end



  // Track each independent AXI channel and retain responses under writeback backpressure.
  always_comb begin
    state_d     = state_q;
    lsu_req_d   = lsu_req_q;
    writeback_d = writeback_q;
    aw_handshake_occurred_d = aw_handshake_occurred_q;
    w_handshake_occurred_d  = w_handshake_occurred_q;

    unique case (state_q)
      LSU_IDLE: begin
        if (lsu_req_handshake) begin
          lsu_req_d = lsu_req_i;
          aw_handshake_occurred_d = 1'b0;
          w_handshake_occurred_d  = 1'b0;

          if (complete_without_dmem) begin
            if (lsu_writeback_handshake) begin
              state_d = LSU_IDLE;
            end else begin
              writeback_d = no_dmem_writeback;
              state_d     = LSU_HOLD_WRITEBACK;
            end
          end else if (is_load) begin
            if (ar_handshake) begin
              state_d = LSU_WAIT_R;
            end else begin
              state_d = LSU_SEND_AR;
            end
          end else if (is_store) begin
            aw_handshake_occurred_d = aw_handshake;
            w_handshake_occurred_d  = w_handshake;
            if (aw_handshake && w_handshake) begin
              state_d = LSU_WAIT_B;
            end else begin
              state_d = LSU_SEND_AW_W;
            end
          end
        end
      end

      LSU_SEND_AR: begin
        if (ar_handshake) begin
          state_d = LSU_WAIT_R;
        end
      end

      LSU_SEND_AW_W: begin
        if (aw_handshake) aw_handshake_occurred_d = 1'b1;
        if (w_handshake) w_handshake_occurred_d = 1'b1;

        if ((aw_handshake_occurred_q || aw_handshake) &&
            (w_handshake_occurred_q  || w_handshake)) begin
          state_d = LSU_WAIT_B;
        end
      end

      LSU_WAIT_R: begin
        if (r_handshake) begin
          if (lsu_writeback_handshake) begin
            lsu_req_d = '0;
            state_d   = LSU_IDLE;
          end else begin
            writeback_d = dmem_writeback;
            state_d     = LSU_HOLD_WRITEBACK;
          end
        end
      end

      LSU_WAIT_B: begin
        if (b_handshake) begin
          aw_handshake_occurred_d = 1'b0;
          w_handshake_occurred_d  = 1'b0;

          if (lsu_writeback_handshake) begin
            lsu_req_d = '0;
            state_d   = LSU_IDLE;
          end else begin
            writeback_d = dmem_writeback;
            state_d     = LSU_HOLD_WRITEBACK;
          end
        end
      end

      LSU_HOLD_WRITEBACK: begin
        if (lsu_writeback_handshake) begin
          lsu_req_d   = '0;
          writeback_d = '0;
          aw_handshake_occurred_d = 1'b0;
          w_handshake_occurred_d  = 1'b0;
          state_d     = LSU_IDLE;
        end
      end

      default: begin
        state_d     = LSU_IDLE;
        lsu_req_d   = '0;
        writeback_d = '0;
        aw_handshake_occurred_d = 1'b0;
        w_handshake_occurred_d  = 1'b0;
      end
    endcase
  end
  // TODO(AXI-LSU-ASSERT): Add protocol assertions after the interface is integrated:
  // master侧至少增加这些协议断言：
  // - 各VALID && !READY时，下一拍VALID仍为1且对应payload保持稳定。
  // - AW握手次数、W握手次数和B握手次数对每个store恰好各一次。
  // - 未发AR时不能接受R，AW/W未全部完成时不能接受B。
  // - load期间AWVALID/WVALID=0，store期间ARVALID=0。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= LSU_IDLE;
      lsu_req_q   <= '0;
      writeback_q <= '0;
      aw_handshake_occurred_q <= 1'b0;
      w_handshake_occurred_q  <= 1'b0;
    end else begin
      state_q     <= state_d;
      lsu_req_q   <= lsu_req_d;
      writeback_q <= writeback_d;
      aw_handshake_occurred_q <= aw_handshake_occurred_d;
      w_handshake_occurred_q  <= w_handshake_occurred_d;
    end
  end

  // 当前单发射核没有并行年轻访存，暂不增加redirect端口。未来乱序版本中load响应使用
  // ROB/LSQ tag判断有效性；store必须在ROB commit授权后进入store buffer并对cache可见。



  // TODO(AXI-LSU-PERF-UPGRADE): 第一次实现维持单outstanding，但不要人为串行AW和W。
  // 后续性能升级顺序：
  // 1. lsu_req入口加1-entry skid buffer，AXI反压时仍能可靠保存payload。
  // 2. R/B接收各加1-entry response buffer，使RREADY/BREADY尽可能常高。
  // 3. 若允许多个outstanding Lite事务，增加按请求顺序保存元数据的load/store FIFO；
  //    Lite没有ID，不能乱序匹配响应。
  // 4. 若需要cache-line burst、多个ID或乱序响应，升级cache外侧为完整AXI4，不要扩展
  //    这个Lite接口的私有字段。
  // 5. 未来乱序CPU的store必须先经ROB commit授权进入store buffer，协议转换不能替代
  //    精确异常和memory ordering设计。
  //
  // NOTE(P5): replace the single transaction state with a load queue, store queue,
  // store buffer, replay path, and cache transaction tracking.

endmodule
