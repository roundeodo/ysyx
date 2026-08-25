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

    // 请求侧预测器是组合查询接口。IFU用即将发出的请求PC查询，并在请求握手时保存
    // prediction；响应回来后不再重新译码指令或计算next PC。
    output program_counter_t   next_pc_predictor_lookup_pc_o,
    input  branch_prediction_t next_pc_predictor_prediction_i,
    input  fetch_control_flow_prediction_context_t next_pc_predictor_context_i,
    input  program_counter_t   next_pc_predictor_next_pc_i,

    // IFU只描述取指语义，不感知cache组织、refill顺序或AXI4通道。
    output icache_lookup_req_t  icache_lookup_req_o,
    output logic                icache_lookup_req_valid_o,
    input  logic                icache_lookup_req_ready_i,
    input  icache_lookup_resp_t icache_lookup_resp_i,
    input  logic                icache_lookup_resp_valid_i,
    output logic                icache_lookup_resp_ready_o,

    output fetch_entry_t fetch_entry_o,
    output logic         fetch_entry_valid_o,
    input  logic         fetch_entry_ready_i,
    output fetch_control_flow_prediction_context_t fetch_prediction_context_o
);

  // 当前前端只允许一个lookup在途，因此控制器只有“发送请求”和“等待响应”两个状态。
  // 等待状态允许在当前响应交付的同一拍发送下一顺序请求：旧事务离开、新事务进入后，
  // 在途数量仍为1，却消除了每个I-cache hit之间固定存在的一拍请求气泡。
  // I-cache内部的hit、miss和refill过程不泄漏到IFU；响应保持由I-cache响应通道负责。
  // 将来支持多个lookup同时在途时，应增加request queue和response matching，而不是继续
  // 堆叠FSM状态。
  typedef enum logic {
    IFU_SEND_LOOKUP,
    IFU_WAIT_LOOKUP_RESPONSE
  } ifu_state_e;

  ifu_state_e state_q;
  ifu_state_e state_d;

  // IFU保存的是架构控制流位置；I-cache接口上的fetch_addr才是物理地址。
  program_counter_t lookup_pc_q;
  program_counter_t lookup_pc_d;
  program_counter_t next_fetch_request_pc_q;
  program_counter_t next_fetch_request_pc_d;

  frontend_tag_t next_frontend_tag_q;
  frontend_tag_t next_frontend_tag_d;
  // lookup_fetch_epoch属于当前请求payload，在valid等待ready期间必须保持不变；
  // current_fetch_epoch描述最新控制流，可在redirect到来时立即递增以淘汰旧响应。
  fetch_epoch_t lookup_fetch_epoch_q;
  fetch_epoch_t lookup_fetch_epoch_d;
  fetch_epoch_t current_fetch_epoch_q;
  fetch_epoch_t current_fetch_epoch_d;

  // 当前唯一在途lookup所采用的预测。它与请求PC、tag和epoch在同一次请求握手时采样，
  // 因此I-cache响应回来时可以直接附到对应fetch entry，供EX精确检查实际后继PC。
  branch_prediction_t lookup_prediction_q;
  branch_prediction_t lookup_prediction_d;
  fetch_control_flow_prediction_context_t lookup_prediction_context_q;
  fetch_control_flow_prediction_context_t lookup_prediction_context_d;

  // I-cache响应在这里组合转换为前端entry；IFU不重复保存payload。
  // IFU负责PC和请求身份，I-cache负责命中、refill以及反压期间的响应保持。
  fetch_entry_t lookup_response_fetch_entry;

  logic lookup_request_handshake;
  logic lookup_response_handshake;
  logic lookup_response_is_current;

  assign lookup_request_handshake = icache_lookup_req_valid_o && icache_lookup_req_ready_i;
  assign lookup_response_handshake = icache_lookup_resp_valid_i && icache_lookup_resp_ready_o;

  // SEND状态查询当前待发送PC；WAIT状态预先查询当前响应交付后将发送的预测后继PC。
  // 这样I-cache响应只负责触发下一请求握手，不再位于预测组合路径上。
  assign next_pc_predictor_lookup_pc_o =
      (state_q == IFU_SEND_LOOKUP) ? lookup_pc_q : next_fetch_request_pc_q;

  // 响应是否属于当前控制流只由请求携带的epoch决定。不能用组合redirect压低valid，
  // 否则当前响应经过IDU/EXU产生redirect后会反向改变自身valid，构成组合环。
  // 当前核心在旧指令尚未完成时会反压IDU，因此年轻响应不会被同期接受；redirect递增
  // epoch后，跨周期保留在I-cache响应通道中的旧响应会在这里被直接排空。
  assign lookup_response_is_current =
      icache_lookup_resp_i.fetch_epoch == current_fetch_epoch_q;
  assign fetch_prediction_context_o = lookup_prediction_context_q;

  always_comb begin
    lookup_response_fetch_entry                 = '0;
    lookup_response_fetch_entry.pc              = program_counter_t'(icache_lookup_resp_i.fetch_addr);
    lookup_response_fetch_entry.instruction     = icache_lookup_resp_i.fetch_data;
    lookup_response_fetch_entry.frontend_tag    = icache_lookup_resp_i.frontend_tag;
    lookup_response_fetch_entry.prediction      = lookup_prediction_q;
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

      IFU_WAIT_LOOKUP_RESPONSE: begin
        // All redirect sources are registered or originate at commit. A redirect
        // therefore makes the currently returned lookup younger than the chosen
        // recovery point; drain it without presenting it to the fetch buffer.
        fetch_entry_valid_o = icache_lookup_resp_valid_i && lookup_response_is_current &&
                              !redirect_req_valid_i;
        icache_lookup_resp_ready_o = (!lookup_response_is_current || redirect_req_valid_i) ?
                                     1'b1 : fetch_entry_ready_i;

        // 只在当前响应确实会交付给IDU时提前呈现下一顺序请求。redirect优先级更高，
        // 发生redirect的当拍不能继续发送旧控制流的PC+4。请求若被反压，状态更新逻辑
        // 会把这里呈现的payload转存为SEND_LOOKUP状态使用的当前请求，保证协议稳定。
        if (lookup_response_handshake && lookup_response_is_current &&
            !redirect_req_valid_i) begin
          icache_lookup_req_o.fetch_addr   = phys_addr_t'(next_fetch_request_pc_q);
          icache_lookup_req_o.frontend_tag = next_frontend_tag_q;
          icache_lookup_req_o.fetch_epoch  = current_fetch_epoch_q;
          icache_lookup_req_valid_o        = 1'b1;
        end
      end

      default: ;
    endcase
  end

  // redirect只立即更新“下一次取指请求地址”和当前控制流epoch，不改写已经呈现在请求通道
  // 上的PC、tag和epoch。即使I-cache正在反压，请求payload也会稳定到握手发生。
  // next_fetch_request_pc表示“当前在途请求结束后，下一次向I-cache请求哪个PC”。因此
  // redirect与response同拍时也必须使用本拍更新后的next_fetch_request_pc_d，不能使用旧的
  // next_fetch_request_pc_q。连续多个redirect发生时，最后一次目标覆盖前一次目标，并通过
  // 递增epoch使更早控制流的返回项全部失效。
  always_comb begin
    state_d                  = state_q;
    lookup_pc_d              = lookup_pc_q;
    next_fetch_request_pc_d  = next_fetch_request_pc_q;
    next_frontend_tag_d      = next_frontend_tag_q;
    lookup_fetch_epoch_d     = lookup_fetch_epoch_q;
    current_fetch_epoch_d    = current_fetch_epoch_q;
    lookup_prediction_d      = lookup_prediction_q;
    lookup_prediction_context_d = lookup_prediction_context_q;

    if (redirect_req_valid_i) begin
      next_fetch_request_pc_d = redirect_req_i.target_pc;
      current_fetch_epoch_d   = current_fetch_epoch_q + fetch_epoch_t'(1);
    end

    unique case (state_q)
      IFU_SEND_LOOKUP: begin
        if (lookup_request_handshake) begin
          state_d                = IFU_WAIT_LOOKUP_RESPONSE;
          next_frontend_tag_d    = next_frontend_tag_q + frontend_tag_t'(1);
          lookup_prediction_d    = next_pc_predictor_prediction_i;
          lookup_prediction_context_d = next_pc_predictor_context_i;
          // redirect可能与上一条lookup响应握手同拍出现。此时状态在时钟沿后已经回到
          // SEND_LOOKUP，但lookup_pc_q/lookup_fetch_epoch_q仍属于旧控制流；即使随后旧请求
          // 被I-cache接受，也只能等待并丢弃它的响应，不能用lookup_pc_q + 4覆盖已经保存
          // 在next_fetch_request_pc_d中的redirect目标。epoch相等才说明本次请求属于当前控制流。
          if (!redirect_req_valid_i &&
              (lookup_fetch_epoch_q == current_fetch_epoch_q)) begin
            // ICACHE_FETCH_BYTES描述一次cache lookup返回多少字节，不等于ISA顺序PC步长。
            // 将二者解耦后，扩大cache line或未来一次取多条指令都不会让PC错误跳过指令。
            next_fetch_request_pc_d = next_pc_predictor_next_pc_i;
          end
        end
      end
      IFU_WAIT_LOOKUP_RESPONSE: begin
        if (lookup_response_handshake) begin
          if (lookup_request_handshake) begin
            // 当前响应与下一顺序请求同拍完成。新请求已经成为唯一在途请求，因此继续
            // 停留在WAIT状态，并为再下一条顺序指令准备PC和tag。
            lookup_pc_d              = next_fetch_request_pc_q;
            next_fetch_request_pc_d  = next_pc_predictor_next_pc_i;
            lookup_fetch_epoch_d     = current_fetch_epoch_q;
            lookup_prediction_d      = next_pc_predictor_prediction_i;
            lookup_prediction_context_d = next_pc_predictor_context_i;
            next_frontend_tag_d      = next_frontend_tag_q + frontend_tag_t'(1);
            state_d                  = IFU_WAIT_LOOKUP_RESPONSE;
          end else begin
            // 响应已经离开，但下一请求未被I-cache接收。把本拍呈现的下一请求转为
            // SEND状态持有的payload；若本拍同时redirect，这里采用redirect更新后的
            // next_fetch_request_pc_d和current_fetch_epoch_d。
            lookup_pc_d          = next_fetch_request_pc_d;
            lookup_fetch_epoch_d = current_fetch_epoch_d;
            state_d              = IFU_SEND_LOOKUP;
          end
        end
      end

      default: begin
        state_d                  = IFU_SEND_LOOKUP;
        lookup_pc_d              = PC_START;
        next_fetch_request_pc_d  = PC_START;
        next_frontend_tag_d      = '0;
        lookup_fetch_epoch_d     = '0;
        current_fetch_epoch_d    = '0;
        lookup_prediction_d      = '0;
        lookup_prediction_context_d = '0;
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
      next_fetch_request_pc_q  <= PC_START;
      next_frontend_tag_q      <= '0;
      lookup_fetch_epoch_q     <= '0;
      current_fetch_epoch_q    <= '0;
      lookup_prediction_q      <= '0;
      lookup_prediction_context_q <= '0;
    end else begin
      lookup_pc_q              <= lookup_pc_d;
      next_fetch_request_pc_q  <= next_fetch_request_pc_d;
      next_frontend_tag_q      <= next_frontend_tag_d;
      lookup_fetch_epoch_q     <= lookup_fetch_epoch_d;
      current_fetch_epoch_q    <= current_fetch_epoch_d;
      lookup_prediction_q      <= lookup_prediction_d;
      lookup_prediction_context_q <= lookup_prediction_context_d;
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

  // 当前响应能够交付且没有redirect时，下一顺序请求必须在同一拍呈现。该断言检查
  // 固定请求气泡不会再次被引入，但不要求I-cache必须接收请求；active miss仍可反压。
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == IFU_WAIT_LOOKUP_RESPONSE && icache_lookup_resp_valid_i &&
     lookup_response_is_current && fetch_entry_ready_i && !redirect_req_valid_i)
    |-> (icache_lookup_req_valid_o &&
         (icache_lookup_req_o.fetch_addr == phys_addr_t'(next_fetch_request_pc_q)) &&
         (icache_lookup_req_o.frontend_tag == next_frontend_tag_q) &&
         (icache_lookup_req_o.fetch_epoch == current_fetch_epoch_q)))
  else $error("IFU did not present the next sequential lookup with a delivered response");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (state_q == IFU_WAIT_LOOKUP_RESPONSE && redirect_req_valid_i)
    |-> (!icache_lookup_req_valid_o && !fetch_entry_valid_o && icache_lookup_resp_ready_o))
  else $error("IFU did not suppress old-path traffic during redirect");
`endif

endmodule
