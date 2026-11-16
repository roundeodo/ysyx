// 单请求cache模型：独立随机请求/响应/交付反压，以及外部恢复优先级。
module early_target_tb #(parameter bit RETURN_TEST = 0);
  import riscv32_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  program_counter_t query_pc,response_pc;
  fetch_epoch_t query_epoch,response_epoch;
  branch_prediction_t prediction;
  logic call_training = 1'b0;
  program_counter_t call_pc = 32'h8000002c;
  logic ras_present;
  program_counter_t ras_pc;
  logic query_valid,query_ready,response_valid,response_ready,flush;
  redirect_req_t redirect;
  logic redirect_valid=0, enabled=1;
  icache_lookup_req_t request, pending_request;
  icache_lookup_resp_t response;
  logic request_valid,request_ready,response_present=0,response_valid_cache,response_ready_cache;
  fetch_entry_t fetched;
  logic fetched_valid,fetched_ready=0;
  int delay_cycles=0, cycle=0, deliveries=0, overrides=0, simultaneous=0, held_redirect=0;
  int seed=1;logic [31:0] random_q=1;
  program_counter_t expected_pc=32'h80000000;
  logic accept_gate=0;
  function automatic logic [31:0] jal(input int displacement);
    logic [20:0] imm;
    imm=21'(displacement);
    return {imm[20],imm[10:1],imm[11],imm[19:12],5'b0,7'b1101111};
  endfunction
  function automatic logic [31:0] instruction(input program_counter_t pc);
    case(pc[5:2])
      0:return jal(32);
      8:return RETURN_TEST ? 32'h00008067 : 32'h00000013; // jalr x0,x1,0
      9:return 32'hfe000ee3; // beq x0,x0,-4: backward, static taken.
      15:return jal(-60);
      default:return 32'h00000013;
    endcase
  endfunction
  function automatic program_counter_t successor(input program_counter_t pc);
    case(pc[5:2])
      0:return pc+32;
      8:return RETURN_TEST ? 32'h80000030 : pc+4;
      9:return pc-4;
      15:return pc-60;
      default:return pc+4;
    endcase
  endfunction
  riscv32_ifu #(.PC_START(32'h80000000)) ifu (
    .clk_i(clk),.rst_ni(rst_n),.redirect_req_i(redirect),.redirect_req_valid_i(redirect_valid),
    .prediction_enable_i(enabled),
    .early_return_present_i(ras_present),.early_return_pc_i(ras_pc),
    .next_pc_predictor_lookup_request_pc_o(query_pc),.next_pc_predictor_lookup_request_epoch_o(query_epoch),
    .next_pc_predictor_lookup_request_valid_o(query_valid),.next_pc_predictor_lookup_request_ready_i(query_ready),
    .next_pc_predictor_lookup_response_pc_i(response_pc),.next_pc_predictor_lookup_response_epoch_i(response_epoch),
    .next_pc_predictor_prediction_i(prediction),.next_pc_predictor_lookup_response_valid_i(response_valid),
    .next_pc_predictor_lookup_response_ready_o(response_ready),.next_pc_predictor_flush_o(flush),
    .icache_lookup_req_o(request),.icache_lookup_req_valid_o(request_valid),.icache_lookup_req_ready_i(request_ready),
    .icache_lookup_resp_i(response),.icache_lookup_resp_valid_i(response_valid_cache),.icache_lookup_resp_ready_o(response_ready_cache),
    .fetch_entry_o(fetched),.fetch_entry_valid_o(fetched_valid),.fetch_entry_ready_i(fetched_ready));
  riscv32_branch_predictor predictor (
    .clk_i(clk),.rst_ni(rst_n),.lookup_request_pc_i(query_pc),.lookup_request_epoch_i(query_epoch),
    .lookup_request_valid_i(query_valid),.lookup_request_ready_o(query_ready),.lookup_response_pc_o(response_pc),
    .lookup_response_epoch_o(response_epoch),.lookup_prediction_o(prediction),.lookup_next_pc_o(),
    .lookup_response_valid_o(response_valid),.lookup_response_ready_i(response_ready),
    .resolved_control_flow_pc_i(call_pc),.resolved_control_flow_target_i(call_pc+32'd4),.resolved_control_flow_imm_i('0),
    .resolved_control_flow_op_i(CF_JAL),.resolved_control_flow_rs1_i('0),.resolved_control_flow_rd_i(5'd1),
    .resolved_control_flow_event_i(call_training),.resolved_control_flow_taken_i(1'b1),.resolved_control_flow_prediction_i('0),
    .early_return_present_o(ras_present),.early_return_pc_o(ras_pc),
    .flush_lookup_i(flush),.invalidate_i(1'b0));
  assign response_valid_cache=response_present && delay_cycles==0;
  assign request_ready=accept_gate && (!response_present || (response_valid_cache && response_ready_cache));
  always_comb begin
    response='0;
    response.fetch_addr=pending_request.fetch_addr;
    response.fetch_data=instruction(pending_request.fetch_addr);
    response.frontend_tag=pending_request.frontend_tag;
    response.fetch_epoch=pending_request.fetch_epoch;
  end
  always @(negedge clk) begin
    if(rst_n) begin
      random_q = {random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
      call_training=RETURN_TEST && cycle%37==0;
      call_pc=random_q[8] ? 32'h8000002c : 32'h80000034;
      fetched_ready=random_q[0] || random_q[1];
      accept_gate=random_q[2] || random_q[3];
      redirect_valid=(cycle%97)==96;
      redirect='0;
      redirect.target_pc=32'h80000000+32'(((cycle/97)%16)*4);
      enabled=(cycle%131)<117;
    end
  end
  always @(posedge clk) begin
    if(rst_n) begin
      cycle++;
      if(redirect_valid) begin
        expected_pc=redirect.target_pc;
        simultaneous+=int'(response_valid_cache);
        held_redirect+=int'(request_valid && !request_ready);
        assert(!fetched_valid) else $fatal(1,"external recovery did not suppress delivery");
      end
      if(fetched_valid && fetched_ready) begin
        assert(fetched.pc==expected_pc) else $fatal(1,"early path skipped or repeated pc: %h != %h",fetched.pc,expected_pc);
        if (!(RETURN_TEST && fetched.pc[5:2]==8))
        assert((fetched.prediction.predicted_taken ? fetched.prediction.predicted_target : fetched.pc+4)==successor(fetched.pc))
          else $fatal(1,"early prediction mismatch pc=%h got=%h expected=%h ras=%h present=%b",fetched.pc,fetched.prediction.predicted_taken ? fetched.prediction.predicted_target : fetched.pc+4,successor(fetched.pc),ras_pc,ras_present);
        expected_pc=(RETURN_TEST && fetched.pc[5:2]==8) ? fetched.prediction.predicted_target : successor(fetched.pc);
        deliveries++;
      end
      overrides+=int'(ifu.early_redirect_event);
      if(response_present && delay_cycles!=0)delay_cycles<=delay_cycles-1;
      if(response_valid_cache && response_ready_cache)response_present<=0;
      if(request_valid && request_ready)begin
        pending_request<=request;response_present<=1;delay_cycles<=int'(random_q[7:4]);
      end
      if(cycle==12000)begin
        assert(deliveries>200 && overrides>40 && simultaneous>0 && held_redirect>0)
          else $fatal(1,"missing mandatory recovery coverage");
        $display("PASS early-target seed=%0d deliveries=%0d overrides=%0d response_redirect=%0d held_redirect=%0d",seed,deliveries,overrides,simultaneous,held_redirect);
        $finish;
      end
    end
  end
  initial begin
    if($value$plusargs("seed=%d",seed))random_q=32'(seed);
    redirect='0;
    repeat(3)@(negedge clk);rst_n=1;call_training=RETURN_TEST;
  end
endmodule
