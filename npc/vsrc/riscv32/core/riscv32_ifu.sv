module riscv32_ifu
  import riscv32_pkg::*;
#(
    parameter logic [XLEN-1:0] PC_START = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    input redirect_req_t redirect_req_i,
    input logic          redirect_req_valid_i,

    // IFU只描述取指语义，不感知cache组织、refill顺序或AXI4通道。
    output icache_lookup_req_t  icache_lookup_req_o,
    output logic                icache_lookup_req_valid_o,
    input  logic                icache_lookup_req_ready_i,
    input  icache_lookup_resp_t icache_lookup_resp_i,
    input  logic                icache_lookup_resp_valid_i,
    output logic                icache_lookup_resp_ready_o,

    output fetch_entry_t fetch_entry_o,
    output logic         fetch_entry_valid_o,
    input  logic         fetch_entry_ready_i
);

  // 当前前端只允许一个lookup在途。I-cache可以在内部命中、miss或refill，
  // IFU只等待最终lookup response。接口中保留tag和epoch，使后续扩展fetch queue、
  // 多MSHR和多个在途请求时不需重新定义IFU/I-cache边界。
  // TODO(IFU-1): 将当前四状态控制器收敛为“发送请求/等待响应”两个状态。
  // 请在本TODO正下方修改枚举：
  //
  //   typedef enum logic {
  //     IFU_SEND_LOOKUP,
  //     IFU_WAIT_LOOKUP_RESPONSE
  //   } ifu_state_e;
  //
  // 删除IFU_INIT：复位时可直接进入IFU_SEND_LOOKUP，不需要用一个空闲周期完成初始化。
  // 删除IFU_HOLD_FETCH_ENTRY：响应保存属于独立fetch buffer的职责，不应在IFU中再复制一份。
  // 当前阶段仍只允许一个lookup在途，因此两个状态足够。将来支持多在途取指时，应增加
  // request queue、response matching和outstanding request table，而不是继续堆叠FSM状态。
  typedef enum logic [1:0] {
    IFU_SEND_LOOKUP,
    IFU_WAIT_LOOKUP_RESPONSE
  } ifu_state_e;

  ifu_state_e state_q;
  ifu_state_e state_d;

  logic [XLEN-1:0] lookup_pc_q;
  logic [XLEN-1:0] lookup_pc_d;
  logic [XLEN-1:0] resume_pc_q;
  logic [XLEN-1:0] resume_pc_d;

  frontend_tag_t next_frontend_tag_q;
  frontend_tag_t next_frontend_tag_d;

  // TODO(IFU-2): 增加独立的请求epoch寄存器，不能直接把current_fetch_epoch_q接到
  // lookup请求payload。请在本TODO正下方增加：
  //
  //   fetch_epoch_t lookup_request_epoch_q;
  //   fetch_epoch_t lookup_request_epoch_d;
  //
  // lookup_request_epoch_q属于当前正在发送的请求，valid && !ready期间必须保持不变；
  // current_fetch_epoch_q属于当前有效控制流，redirect到来时必须立即递增。两者分离后，
  // stalled旧请求可以保持原epoch完成握手，其返回项再由current epoch判断为失效。
  fetch_epoch_t lookup_request_epoch_q;
  fetch_epoch_t lookup_request_epoch_d;

  // TODO(IFU-3): 删除IFU内部的buffered_fetch_entry_q/d和fetch_entry_handshake，
  // 只保留
  // lookup_response_fetch_entry作为I-cache响应到fetch_entry_t的组合格式转换结果。
  // 修改后的声明应为：
  //
  //   fetch_entry_t lookup_response_fetch_entry;
  //
  // 模块边界应明确划分：
  //   1. IFU：选择下一取指PC、发起lookup、维护frontend_tag和fetch_epoch；
  //   2. I-cache：完成PMA检查、tag/data访问、命中判断和miss/refill；
  //   3. fetch buffer：在I-cache响应与IDU反压之间保存fetch_entry。
  // 独立fetch buffer以后可以参数化深度、扩展为队列，并允许前端在IDU短暂阻塞时继续取指；
  // IFU中保留一项私有buffer会形成重复状态和重复反压路径，妨碍这种扩展。
  fetch_entry_t lookup_response_fetch_entry;

  logic lookup_request_handshake;
  logic lookup_response_handshake;
  logic fetch_entry_handshake;
  logic lookup_response_is_current;

  assign lookup_request_handshake   = icache_lookup_req_valid_o && icache_lookup_req_ready_i;
  assign lookup_response_handshake  = icache_lookup_resp_valid_i && icache_lookup_resp_ready_o;
  assign fetch_entry_handshake      = fetch_entry_valid_o && fetch_entry_ready_i;

  // TODO(IFU-4): redirect发生的同一拍也必须把I-cache返回项视为旧控制流数据。
  // 将下面的判断改为：
  //
  //   assign lookup_response_is_current =
  //       !redirect_req_valid_i
  //       && (icache_lookup_resp_i.fetch_epoch == current_fetch_epoch_q);
  //
  // epoch用于区分redirect前后的取指流。redirect一旦有效，前端必须立即禁止旧响应进入
  // fetch buffer；即使响应携带的epoch等于寄存器中的旧epoch，它在本拍也已失效。
  // 失效响应仍必须握手并排空，否则单在途IFU会永久等待该响应，无法从redirect目标重新取指。
  assign lookup_response_is_current = icache_lookup_resp_i.fetch_epoch == current_fetch_epoch_q;

  always_comb begin
    lookup_response_fetch_entry                 = '0;
    lookup_response_fetch_entry.pc              = icache_lookup_resp_i.fetch_addr;
    lookup_response_fetch_entry.instruction     = icache_lookup_resp_i.fetch_data;
    lookup_response_fetch_entry.frontend_tag    = icache_lookup_resp_i.frontend_tag;
    lookup_response_fetch_entry.prediction      = '0;
    lookup_response_fetch_entry.exception_valid = icache_lookup_resp_i.access_fault;
    lookup_response_fetch_entry.exception_cause = EXC_INSTR_ACCESS_FAULT;
    lookup_response_fetch_entry.exception_tval  = icache_lookup_resp_i.fetch_addr;
  end

  // TODO(IFU-5): 用下面的框架完整替换当前输出逻辑。这里实现两条不同的响应规则：
  // 当前epoch响应只有在fetch buffer能够接收时才与I-cache握手；旧epoch响应则无条件排空。
  //
  //   always_comb begin
  //     icache_lookup_req_o        = '0;
  //     icache_lookup_req_valid_o  = 1'b0;
  //     icache_lookup_resp_ready_o = 1'b0;
  //     fetch_entry_o              = lookup_response_fetch_entry;
  //     fetch_entry_valid_o        = 1'b0;
  //
  //     unique case (state_q)
  //       IFU_SEND_LOOKUP: begin
  //         icache_lookup_req_o.fetch_addr   = lookup_pc_q;
  //         icache_lookup_req_o.frontend_tag = next_frontend_tag_q;
  //         icache_lookup_req_o.fetch_epoch  = lookup_request_epoch_q;
  //         icache_lookup_req_valid_o        = 1'b1;
  //       end
  //
  //       IFU_WAIT_LOOKUP_RESPONSE: begin
  //         fetch_entry_valid_o =
  //             icache_lookup_resp_valid_i && lookup_response_is_current;
  //         icache_lookup_resp_ready_o =
  //             lookup_response_is_current ? fetch_entry_ready_i : 1'b1;
  //       end
  //
  //       default: ;
  //     endcase
  //   end
  //
  // 当前响应的两个握手必须是同一件事：当resp_valid、epoch匹配且fetch_entry_ready同时
  // 成立时，IFU才既消费I-cache响应又向fetch buffer交付entry，不能只完成其中一侧。
  // 旧响应不交付fetch_entry，但ready固定为1，使其尽快离开返回通道。
  // fetch_entry_ready_i在后续顶层连接中应来自独立fetch buffer，而不是直接来自IDU。
  always_comb begin
    icache_lookup_req_o        = '0;
    icache_lookup_req_valid_o  = 1'b0;
    icache_lookup_resp_ready_o = 1'b0;
    fetch_entry_o              = buffered_fetch_entry_q;
    fetch_entry_valid_o        = 1'b0;

    unique case (state_q)
      IFU_INIT: ;

      IFU_SEND_LOOKUP: begin
        icache_lookup_req_o.fetch_addr   = lookup_pc_q;
        icache_lookup_req_o.frontend_tag = next_frontend_tag_q;
        icache_lookup_req_o.fetch_epoch  = current_fetch_epoch_q;
        icache_lookup_req_valid_o        = 1'b1;
      end

      IFU_WAIT_LOOKUP_RESPONSE: begin
        icache_lookup_resp_ready_o = 1'b1;
        fetch_entry_o              = lookup_response_fetch_entry;
        fetch_entry_valid_o        = icache_lookup_resp_valid_i && lookup_response_is_current;
      end

      IFU_HOLD_FETCH_ENTRY: begin
        fetch_entry_o       = buffered_fetch_entry_q;
        fetch_entry_valid_o = 1'b1;
      end

      default: ;
    endcase
  end

  // TODO(IFU-6): 用下面的框架完整替换下一状态逻辑，并删除buffered_fetch_entry_d相关代码。
  // 重点是严格遵守valid-ready稳定性：请求valid=1而ready=0时，不允许redirect直接改写
  // lookup_pc_q。此时先保存redirect目标到resume_pc_d并递增epoch；旧请求完成握手和返回后，
  // 再从最新resume_pc重新发起请求。否则I-cache会看到同一个valid对应变化的payload。
  //
  //   always_comb begin
  //     state_d               = state_q;
  //     lookup_pc_d           = lookup_pc_q;
  //     resume_pc_d           = resume_pc_q;
  //     next_frontend_tag_d   = next_frontend_tag_q;
  //     lookup_request_epoch_d = lookup_request_epoch_q;
  //     current_fetch_epoch_d  = current_fetch_epoch_q;
  //
  //     if (redirect_req_valid_i) begin
  //       resume_pc_d           = redirect_req_i.target_pc;
  //       current_fetch_epoch_d = current_fetch_epoch_q + fetch_epoch_t'(1);
  //     end
  //
  //     unique case (state_q)
  //       IFU_SEND_LOOKUP: begin
  //         if (lookup_request_handshake) begin
  //           state_d             = IFU_WAIT_LOOKUP_RESPONSE;
  //           next_frontend_tag_d = next_frontend_tag_q + frontend_tag_t'(1);
  //           if (!redirect_req_valid_i) begin
  //             resume_pc_d = lookup_pc_q + XLEN'(ICACHE_FETCH_BYTES);
  //           end
  //         end
  //       end
  //
  //       IFU_WAIT_LOOKUP_RESPONSE: begin
  //         if (lookup_response_handshake) begin
  //           lookup_pc_d            = resume_pc_d;
  //           lookup_request_epoch_d = current_fetch_epoch_d;
  //           state_d                = IFU_SEND_LOOKUP;
  //         end
  //       end
  //
  //       default: begin
  //         state_d               = IFU_SEND_LOOKUP;
  //         lookup_pc_d           = PC_START;
  //         resume_pc_d           = PC_START;
  //         next_frontend_tag_d   = '0;
  //         lookup_request_epoch_d = '0;
  //         current_fetch_epoch_d = '0;
  //       end
  //     endcase
  //   end
  //
  // resume_pc表示“当前在途请求结束后应从哪里继续”，因此redirect与response同拍时也必须
  // 使用本拍更新后的resume_pc_d，而不能使用旧的resume_pc_q。连续多个redirect发生时，
  // 最后一次目标覆盖前一次目标，并通过递增epoch使更早控制流的返回项全部失效。
  always_comb begin
    state_d                = state_q;
    lookup_pc_d            = lookup_pc_q;
    resume_pc_d            = resume_pc_q;
    next_frontend_tag_d    = next_frontend_tag_q;
    current_fetch_epoch_d  = current_fetch_epoch_q;
    buffered_fetch_entry_d = buffered_fetch_entry_q;

    if (redirect_req_valid_i) begin
      resume_pc_d           = redirect_req_i.target_pc;
      current_fetch_epoch_d = current_fetch_epoch_q + fetch_epoch_t'(1);
    end

    unique case (state_q)
      IFU_INIT: begin
        state_d = IFU_SEND_LOOKUP;
      end

      IFU_SEND_LOOKUP: begin
        if (lookup_request_handshake) begin
          state_d             = IFU_WAIT_LOOKUP_RESPONSE;
          next_frontend_tag_d = next_frontend_tag_q + frontend_tag_t'(1);
          if (!redirect_req_valid_i) begin
            resume_pc_d = lookup_pc_q + XLEN'(ICACHE_FETCH_BYTES);
          end
        end else if (redirect_req_valid_i) begin
          // 请求尚未被I-cache接收，下一拍可直接用新PC重新发起。
          lookup_pc_d = redirect_req_i.target_pc;
        end
      end

      IFU_WAIT_LOOKUP_RESPONSE: begin
        if (lookup_response_handshake) begin
          if (!lookup_response_is_current) begin
            lookup_pc_d = resume_pc_d;
            state_d     = IFU_SEND_LOOKUP;
          end else if (fetch_entry_handshake) begin
            lookup_pc_d = redirect_req_valid_i ? redirect_req_i.target_pc : resume_pc_q;
            state_d     = IFU_SEND_LOOKUP;
          end else begin
            buffered_fetch_entry_d = lookup_response_fetch_entry;
            state_d                = IFU_HOLD_FETCH_ENTRY;
          end
        end
      end

      IFU_HOLD_FETCH_ENTRY: begin
        if (fetch_entry_handshake) begin
          lookup_pc_d = redirect_req_valid_i ? redirect_req_i.target_pc : resume_pc_q;
          state_d     = IFU_SEND_LOOKUP;
        end
      end

      default: begin
        state_d                = IFU_INIT;
        lookup_pc_d            = PC_START;
        resume_pc_d            = PC_START;
        next_frontend_tag_d    = '0;
        current_fetch_epoch_d  = '0;
        buffered_fetch_entry_d = '0;
      end
    endcase
  end

  // TODO(IFU-7): 按职责保留两个时序块，并删除buffered_fetch_entry_q的时序块。
  // 第一个块只更新FSM，复位值直接改成IFU_SEND_LOOKUP：
  //
  //   always_ff @(posedge clk_i or negedge rst_ni) begin
  //     if (!rst_ni) state_q <= IFU_SEND_LOOKUP;
  //     else         state_q <= state_d;
  //   end
  //
  // 第二个块更新取指地址和请求身份。除现有寄存器外，还要加入IFU-2定义的
  // lookup_request_epoch_q：
  //
  //   always_ff @(posedge clk_i or negedge rst_ni) begin
  //     if (!rst_ni) begin
  //       lookup_pc_q            <= PC_START;
  //       resume_pc_q            <= PC_START;
  //       next_frontend_tag_q    <= '0;
  //       lookup_request_epoch_q <= '0;
  //       current_fetch_epoch_q  <= '0;
  //     end else begin
  //       lookup_pc_q            <= lookup_pc_d;
  //       resume_pc_q            <= resume_pc_d;
  //       next_frontend_tag_q    <= next_frontend_tag_d;
  //       lookup_request_epoch_q <= lookup_request_epoch_d;
  //       current_fetch_epoch_q  <= current_fetch_epoch_d;
  //     end
  //   end
  //
  // 状态与请求上下文分开更新，便于波形定位和后续把请求上下文替换成队列项；
  // 但同一组寄存器仍由一个组合next-state块统一计算，避免出现多个写驱动。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IFU_INIT;
    end else begin
      state_q <= state_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lookup_pc_q           <= PC_START;
      resume_pc_q           <= PC_START;
      next_frontend_tag_q   <= '0;
      current_fetch_epoch_q <= '0;
    end else begin
      lookup_pc_q           <= lookup_pc_d;
      resume_pc_q           <= resume_pc_d;
      next_frontend_tag_q   <= next_frontend_tag_d;
      current_fetch_epoch_q <= current_fetch_epoch_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      buffered_fetch_entry_q <= '0;
    end else begin
      buffered_fetch_entry_q <= buffered_fetch_entry_d;
    end
  end

  // TODO(IFU-8): 完成功能代码后，在本TODO正下方加入协议断言。断言只用于仿真，
  // 用`ifndef SYNTHESIS隔离，不进入综合结果。可以直接采用下面的框架：
  //
  // `ifndef SYNTHESIS
  //   // I-cache尚未接收请求时，valid及整个请求payload必须保持稳定。
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     icache_lookup_req_valid_o && !icache_lookup_req_ready_i
  //     |=> icache_lookup_req_valid_o && $stable(icache_lookup_req_o));
  //
  //   // 当前响应受fetch buffer反压时，响应转换结果和valid必须保持稳定；
  //   // 下一拍出现redirect时允许取消该entry并只排空I-cache响应。
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     fetch_entry_valid_o && !fetch_entry_ready_i && !redirect_req_valid_i
  //     |=> redirect_req_valid_i ||
  //         (fetch_entry_valid_o && $stable(fetch_entry_o)));
  //
  //   // 旧epoch或redirect同拍返回的数据不得进入fetch buffer，并必须允许排空。
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     state_q == IFU_WAIT_LOOKUP_RESPONSE && icache_lookup_resp_valid_i &&
  //     !lookup_response_is_current
  //     |-> icache_lookup_resp_ready_o && !fetch_entry_valid_o);
  //
  //   // frontend tag只允许在lookup请求真正被I-cache接收后递增。
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     next_frontend_tag_q != $past(next_frontend_tag_q)
  //     |-> $past(lookup_request_handshake));
  //
  //   // 单在途实现中，请求通道和响应接收通道不能同时处于活动状态。
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     state_q == IFU_SEND_LOOKUP |-> !icache_lookup_resp_ready_o);
  //   assert property (@(posedge clk_i) disable iff (!rst_ni)
  //     state_q == IFU_WAIT_LOOKUP_RESPONSE |-> !icache_lookup_req_valid_o);
  // `endif
  //
  // 第一条断言会同时检查PC、frontend_tag和lookup_request_epoch，因此能直接发现
  // redirect期间偷偷修改请求身份的问题。断言使用现有握手信号，不要重新复制判定逻辑。

  // TODO(IFU-9): 完成后至少覆盖以下定向场景，再删除本TODO并把场景保留到测试文档：
  //   1. 复位后第一笔lookup地址为PC_START；
  //   2. req_ready连续拉低，请求PC、tag、epoch全程稳定；
  //   3. 顺序取指响应被接收后，下一请求地址增加ICACHE_FETCH_BYTES；
  //   4. fetch buffer反压时，当前响应不被I-cache消费且fetch_entry保持稳定；
  //   5. SEND_LOOKUP受阻时发生redirect，旧请求payload保持不变，旧响应被丢弃；
  //   6. 请求握手与redirect同拍发生，该请求按旧epoch返回并被丢弃；
  //   7. WAIT_LOOKUP_RESPONSE期间发生redirect，响应同拍或延后返回都不能交付旧指令；
  //   8. access_fault响应正确转换为EXC_INSTR_ACCESS_FAULT并保留fault地址；
  //   9. frontend_tag和fetch_epoch发生数值回绕时，握手和控制流仍可继续运行。

endmodule
