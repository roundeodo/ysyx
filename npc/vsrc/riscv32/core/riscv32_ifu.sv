module riscv32_ifu
  import riscv32_pkg::*;
  // PC属于ISA语义，I-cache请求地址属于物理存储系统语义；两类类型显式分属不同package。
  import riscv32_addr_map_pkg::*;
#(
    // 复位入口属于架构PC，不由AXI地址宽度决定。
    parameter program_counter_t PC_START = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    input redirect_req_t redirect_req_i,
    input logic          redirect_req_valid_i,

    // 预测器与I-cache在core中原子接收同一请求，并原子返回同一PC的响应。IFU只消费
    // 已经完成配对的预测结果，不保存另一份可能与I-cache响应错位的预测payload。
    input branch_prediction_t next_pc_predictor_prediction_i,

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

  // 当前前端只允许一个lookup在途。顺序流允许在当前响应交付的同一拍发送PC+4：
  // 旧事务离开、新事务进入后，在途数量仍为1，不会为每个I-cache hit固定插入气泡。
  // taken预测目标先寄存再发出，用一拍taken气泡换取预测器到I-cache之间的时序切分。
  // I-cache内部的hit、miss和refill过程不泄漏到IFU；响应保持由I-cache响应通道负责。
  // 将来支持多个lookup同时在途时，应增加request queue和response matching，而不是继续
  // 堆叠FSM状态。
  typedef enum logic [1:0] {
    IFU_SEND_LOOKUP,
    IFU_SEND_PREDICTED_TARGET,
    IFU_WAIT_LOOKUP_RESPONSE
  } ifu_state_e;

  ifu_state_e state_q;
  ifu_state_e state_d;

  // IFU保存的是架构控制流位置；I-cache接口上的fetch_addr才是物理地址。
  program_counter_t lookup_pc_q;
  program_counter_t lookup_pc_d;
  // redirect到来时，已经呈现在请求通道上的旧PC仍必须保持到握手；最新恢复目标单独保存，
  // 等旧响应按epoch丢弃后再发出，不能用redirect直接改写被反压的valid payload。
  program_counter_t pending_redirect_target_pc_q;
  program_counter_t pending_redirect_target_pc_d;
  // taken目标单独寄存，避免BTB命中比较和目标选择在同一拍继续穿过IFU并驱动
  // I-cache请求寄存器。顺序PC+4仍可同拍发出，只有预测taken时增加一拍请求气泡。
  program_counter_t predicted_target_pc_q;
  program_counter_t predicted_target_pc_d;

  frontend_tag_t next_frontend_tag_q;
  frontend_tag_t next_frontend_tag_d;
  // lookup_fetch_epoch属于当前请求payload，在valid等待ready期间必须保持不变；
  // current_fetch_epoch描述最新控制流，可在redirect到来时立即递增以淘汰旧响应。
  fetch_epoch_t lookup_fetch_epoch_q;
  fetch_epoch_t lookup_fetch_epoch_d;
  fetch_epoch_t current_fetch_epoch_q;
  fetch_epoch_t current_fetch_epoch_d;

  // I-cache响应在这里组合转换为前端entry；IFU不重复保存payload。
  // IFU负责PC和请求身份，I-cache负责命中、refill以及反压期间的响应保持。
  fetch_entry_t lookup_response_fetch_entry;

  logic lookup_request_handshake;
  logic lookup_response_handshake;
  logic lookup_response_is_current;

  assign lookup_request_handshake = icache_lookup_req_valid_o && icache_lookup_req_ready_i;
  assign lookup_response_handshake = icache_lookup_resp_valid_i && icache_lookup_resp_ready_o;

  // 响应是否属于当前控制流只由请求携带的epoch决定。不能用组合redirect压低valid，
  // 否则当前响应经过IDU/EXU产生redirect后会反向改变自身valid，构成组合环。
  // 当前核心在旧指令尚未完成时会反压IDU，因此年轻响应不会被同期接受；redirect递增
  // epoch后，跨周期保留在I-cache响应通道中的旧响应会在这里被直接排空。
  assign lookup_response_is_current =
      icache_lookup_resp_i.fetch_epoch == current_fetch_epoch_q;
  always_comb begin
    lookup_response_fetch_entry                 = '0;
    lookup_response_fetch_entry.pc              = program_counter_t'(icache_lookup_resp_i.fetch_addr);
    lookup_response_fetch_entry.instruction     = icache_lookup_resp_i.fetch_data;
    lookup_response_fetch_entry.frontend_tag    = icache_lookup_resp_i.frontend_tag;
    lookup_response_fetch_entry.prediction      = next_pc_predictor_prediction_i;
    lookup_response_fetch_entry.exception_valid = icache_lookup_resp_i.access_fault;
    lookup_response_fetch_entry.exception_cause = EXC_INSTR_ACCESS_FAULT;
    lookup_response_fetch_entry.exception_tval  = xlen_data_t'(icache_lookup_resp_i.fetch_addr);
  end

  // 当前响应的两个握手必须是同一件事：当resp_valid、epoch匹配且fetch_entry_ready同时
  // 成立时，IFU才既消费I-cache响应又向IDU交付entry，不能只完成其中一侧。
  // 当前响应交付且没有redirect时，下一顺序请求同拍呈现在lookup请求通道。若I-cache
  // 能同拍接收，新请求直接替换旧在途请求；若refill尚未结束导致ready=0，下一拍进入
  // SEND_LOOKUP并继续稳定保持同一个请求。旧响应不交付fetch_entry，但ready固定为1，
  // 使其尽快离开返回通道。
  always_comb begin
    icache_lookup_req_o        = '0;
    icache_lookup_req_valid_o  = 1'b0;
    icache_lookup_resp_ready_o = 1'b0;
    fetch_entry_o              = lookup_response_fetch_entry;
    fetch_entry_valid_o        = 1'b0;

    unique case (state_q)
      IFU_SEND_LOOKUP: begin
        // 当前无地址翻译，转换是恒等映射；未来加入TLB/MMU时在IFU与I-cache之间插入翻译，
        // I-cache仍只接收物理地址，避免虚拟地址别名规则污染cache和AXI refill模块。
        icache_lookup_req_o.fetch_addr   = phys_addr_t'(lookup_pc_q);
        icache_lookup_req_o.frontend_tag = next_frontend_tag_q;
        icache_lookup_req_o.fetch_epoch  = lookup_fetch_epoch_q;
        // 复位时不发起事务；复位释放后无需额外INIT状态即可立即开始取指。
        icache_lookup_req_valid_o        = rst_ni;
      end

      IFU_SEND_PREDICTED_TARGET: begin
        icache_lookup_req_o.fetch_addr   = phys_addr_t'(predicted_target_pc_q);
        icache_lookup_req_o.frontend_tag = next_frontend_tag_q;
        icache_lookup_req_o.fetch_epoch  = lookup_fetch_epoch_q;
        icache_lookup_req_valid_o        = rst_ni;
      end

      IFU_WAIT_LOOKUP_RESPONSE: begin
        // redirect使当前返回项属于已废弃控制流，因此直接排空而不交付fetch buffer。
        fetch_entry_valid_o = icache_lookup_resp_valid_i && lookup_response_is_current &&
                              !redirect_req_valid_i;
        icache_lookup_resp_ready_o = (!lookup_response_is_current || redirect_req_valid_i) ?
                                     1'b1 : fetch_entry_ready_i;

        // 只在当前响应确实会交付给IDU时提前呈现下一顺序请求。redirect优先级更高，
        // 发生redirect的当拍不能继续发送旧控制流的PC+4。请求若被反压，状态更新逻辑
        // 会把这里呈现的payload转存为SEND_LOOKUP状态使用的当前请求，保证协议稳定。
        if (lookup_response_handshake && lookup_response_is_current &&
            !redirect_req_valid_i && !next_pc_predictor_prediction_i.predicted_taken) begin
          icache_lookup_req_o.fetch_addr   = phys_addr_t'(
              lookup_pc_q + program_counter_t'(INSTRUCTION_BYTES)
          );
          icache_lookup_req_o.frontend_tag = next_frontend_tag_q;
          icache_lookup_req_o.fetch_epoch  = current_fetch_epoch_q;
          icache_lookup_req_valid_o        = 1'b1;
        end
      end

      default: ;
    endcase
  end

  // redirect只更新恢复目标和当前控制流epoch，不改写已呈现在请求通道上的PC、tag和epoch。
  // 连续redirect以最新目标为准，每次递增epoch，使此前所有控制流响应都可被确定地丢弃。
  always_comb begin
    state_d                  = state_q;
    lookup_pc_d              = lookup_pc_q;
    pending_redirect_target_pc_d = pending_redirect_target_pc_q;
    predicted_target_pc_d    = predicted_target_pc_q;
    next_frontend_tag_d      = next_frontend_tag_q;
    lookup_fetch_epoch_d     = lookup_fetch_epoch_q;
    current_fetch_epoch_d    = current_fetch_epoch_q;

    if (redirect_req_valid_i) begin
      pending_redirect_target_pc_d = redirect_req_i.target_pc;
      current_fetch_epoch_d        = current_fetch_epoch_q + fetch_epoch_t'(1);
    end

    unique case (state_q)
      IFU_SEND_LOOKUP: begin
        if (lookup_request_handshake) begin
          state_d                = IFU_WAIT_LOOKUP_RESPONSE;
          next_frontend_tag_d    = next_frontend_tag_q + frontend_tag_t'(1);
        end
      end
      IFU_SEND_PREDICTED_TARGET: begin
        if (lookup_request_handshake) begin
          lookup_pc_d           = predicted_target_pc_q;
          state_d               = IFU_WAIT_LOOKUP_RESPONSE;
          next_frontend_tag_d   = next_frontend_tag_q + frontend_tag_t'(1);
        end
      end
      IFU_WAIT_LOOKUP_RESPONSE: begin
        if (lookup_response_handshake) begin
          if (!lookup_response_is_current || redirect_req_valid_i) begin
            // 旧路径响应及其配对预测均在这里排空；下一拍从最新redirect目标重新取指。
            lookup_pc_d          = pending_redirect_target_pc_d;
            lookup_fetch_epoch_d = current_fetch_epoch_d;
            state_d              = IFU_SEND_LOOKUP;
          end else if (next_pc_predictor_prediction_i.predicted_taken) begin
            // taken目标来自BTB/RAS的组合比较结果，先进入专用寄存器，下一拍再请求。
            // 这样预测器复杂度不会限制I-cache请求寄存器的建立时间。
            predicted_target_pc_d = next_pc_predictor_prediction_i.predicted_target;
            lookup_fetch_epoch_d  = current_fetch_epoch_q;
            state_d               = IFU_SEND_PREDICTED_TARGET;
          end else if (lookup_request_handshake) begin
            // 当前响应与下一顺序请求同拍完成。新请求已经成为唯一在途请求，因此继续
            // 停留在WAIT状态，并为再下一条顺序指令准备PC和tag。
            lookup_pc_d          = lookup_pc_q + program_counter_t'(INSTRUCTION_BYTES);
            lookup_fetch_epoch_d = current_fetch_epoch_q;
            next_frontend_tag_d  = next_frontend_tag_q + frontend_tag_t'(1);
            state_d              = IFU_WAIT_LOOKUP_RESPONSE;
          end else begin
            // 响应已经离开，但下一请求未被I-cache接收。把本拍呈现的下一请求转为
            // SEND状态持有的payload，下一拍继续保持同一个预测后继PC直到握手。
            lookup_pc_d          = lookup_pc_q + program_counter_t'(INSTRUCTION_BYTES);
            lookup_fetch_epoch_d = current_fetch_epoch_q;
            state_d              = IFU_SEND_LOOKUP;
          end
        end
      end

      default: begin
        state_d                  = IFU_SEND_LOOKUP;
        lookup_pc_d              = PC_START;
        pending_redirect_target_pc_d = PC_START;
        predicted_target_pc_d    = PC_START;
        next_frontend_tag_d      = '0;
        lookup_fetch_epoch_d     = '0;
        current_fetch_epoch_d    = '0;
      end
    endcase
  end

  // 状态寄存器与请求上下文分组更新。payload由valid位和FSM管理有效性，不在IFU中
  // 另设一份响应寄存器；I-cache响应通道已经提供稳定性，重复存储只会增加面积。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IFU_SEND_LOOKUP;
    end else begin
      state_q <= state_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lookup_pc_q              <= PC_START;
      pending_redirect_target_pc_q <= PC_START;
      predicted_target_pc_q    <= PC_START;
      next_frontend_tag_q      <= '0;
      lookup_fetch_epoch_q     <= '0;
      current_fetch_epoch_q    <= '0;
    end else begin
      lookup_pc_q              <= lookup_pc_d;
      pending_redirect_target_pc_q <= pending_redirect_target_pc_d;
      predicted_target_pc_q    <= predicted_target_pc_d;
      next_frontend_tag_q      <= next_frontend_tag_d;
      lookup_fetch_epoch_q     <= lookup_fetch_epoch_d;
      current_fetch_epoch_q    <= current_fetch_epoch_d;
    end
  end

  // 协议断言检查请求反压稳定性、epoch淘汰和当前响应的原子交付。
`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (icache_lookup_req_valid_o && !icache_lookup_req_ready_i)
    |=> (icache_lookup_req_valid_o && $stable(
      icache_lookup_req_o
  )))
  else $error("IFU changed I-cache lookup request while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == IFU_WAIT_LOOKUP_RESPONSE
     && icache_lookup_resp_valid_i && !lookup_response_is_current)
    |-> (icache_lookup_resp_ready_o && !fetch_entry_valid_o))
  else $error("IFU failed to discard a stale I-cache response");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == IFU_WAIT_LOOKUP_RESPONSE
     && icache_lookup_resp_valid_i && lookup_response_is_current
     && !redirect_req_valid_i)
    |-> (fetch_entry_valid_o
         && (icache_lookup_resp_ready_o == fetch_entry_ready_i)))
  else $error("IFU current response was not coupled to IDU delivery");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == IFU_WAIT_LOOKUP_RESPONSE
     && icache_lookup_resp_valid_i && redirect_req_valid_i)
    |-> (icache_lookup_resp_ready_o && !fetch_entry_valid_o))
  else $error("IFU did not discard the lookup response superseded by redirect");

  // 非taken响应能够交付且没有redirect时，下一顺序请求必须在同一拍呈现。taken目标
  // 则先寄存以切断预测反馈关键路径，下一拍由IFU_SEND_PREDICTED_TARGET发出。
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == IFU_WAIT_LOOKUP_RESPONSE && icache_lookup_resp_valid_i &&
     lookup_response_is_current && fetch_entry_ready_i && !redirect_req_valid_i &&
     !next_pc_predictor_prediction_i.predicted_taken)
    |-> (icache_lookup_req_valid_o &&
         (icache_lookup_req_o.fetch_addr == phys_addr_t'(
             lookup_pc_q + program_counter_t'(INSTRUCTION_BYTES)
         )) &&
         (icache_lookup_req_o.frontend_tag == next_frontend_tag_q) &&
         (icache_lookup_req_o.fetch_epoch == current_fetch_epoch_q)))
  else $error("IFU did not present the next sequential lookup with a delivered response");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lookup_response_handshake && lookup_response_is_current &&
     !redirect_req_valid_i && next_pc_predictor_prediction_i.predicted_taken)
    |=> (state_q == IFU_SEND_PREDICTED_TARGET &&
         predicted_target_pc_q == $past(next_pc_predictor_prediction_i.predicted_target)))
  else $error("IFU did not register a predicted taken target before issuing it");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == IFU_WAIT_LOOKUP_RESPONSE && redirect_req_valid_i)
    |-> (!icache_lookup_req_valid_o && !fetch_entry_valid_o && icache_lookup_resp_ready_o))
  else $error("IFU did not suppress old-path traffic during redirect");

`endif

endmodule
