// 独立行为模型：用顺序软件表和逻辑栈描述状态，不访问 DUT 内部寄存器。
module predictor_contract_case
  import riscv32_pkg::*;
#(parameter int ID=0, BHT=16, BTB=16, WAYS=2, RAS=4)
(output logic done_o);
  localparam int SETS = BTB / WAYS;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  program_counter_t pc, response_pc, next_pc, train_pc, train_target;
  fetch_epoch_t epoch, response_epoch;
  branch_prediction_t prediction;
  logic request_valid, request_ready, response_valid, response_ready, flush, invalidate;
  logic train_valid, train_taken;
  control_flow_op_e train_op;
  arch_reg_idx_t train_rs1, train_rd;
  xlen_data_t train_imm;

  riscv32_branch_predictor #(
      .BHT_ENTRY_COUNT(BHT), .BTB_ENTRY_COUNT(BTB), .BTB_WAY_COUNT(WAYS), .RAS_ENTRY_COUNT(RAS)
  ) dut (
      .clk_i(clk), .rst_ni(rst_n), .lookup_request_pc_i(pc), .lookup_request_epoch_i(epoch),
      .lookup_request_valid_i(request_valid), .lookup_request_ready_o(request_ready),
      .lookup_response_pc_o(response_pc), .lookup_response_epoch_o(response_epoch),
      .lookup_prediction_o(prediction), .lookup_next_pc_o(next_pc),
      .lookup_response_valid_o(response_valid), .lookup_response_ready_i(response_ready),
      .resolved_control_flow_pc_i(train_pc), .resolved_control_flow_target_i(train_target),
      .resolved_control_flow_imm_i(train_imm), .resolved_control_flow_op_i(train_op),
      .resolved_control_flow_rs1_i(train_rs1), .resolved_control_flow_rd_i(train_rd),
      .resolved_control_flow_event_i(train_valid), .resolved_control_flow_taken_i(train_taken),
      .flush_lookup_i(flush), .invalidate_i(invalidate)
  );

  int counters[BHT];
  bit table_valid[BTB];
  program_counter_t table_pc[BTB], table_target[BTB];
  int table_kind[BTB], victim[SETS];
  program_counter_t stack[RAS];
  int stack_size;
  typedef struct packed {
    bit valid;
    bit taken;
    program_counter_t pc, target;
    xlen_data_t imm;
    control_flow_op_e op;
    arch_reg_idx_t rs1, rd;
  } event_t;
  event_t pending;
  bit expected_valid;
  program_counter_t expected_pc;
  fetch_epoch_t expected_epoch;
  branch_prediction_t expected_prediction;
  int queries=0, responses=0, stalls=0, updates=0, clears=0, flushes=0;
  int kind_hits[4];
  int pushes=0, pops=0, swaps=0, saturation=0;
  logic [31:0] random_state = 32'h12abf891 ^ (32'(ID) * 32'h7654321);

  function automatic bit is_link(input arch_reg_idx_t reg_index);
    return reg_index == 1 || reg_index == 5;
  endfunction
  function automatic bit is_return(input event_t e);
    return e.op == CF_JALR && is_link(e.rs1) &&
           (!is_link(e.rd) || e.rd != e.rs1) && e.imm == 0;
  endfunction
  function automatic int classify(input event_t e);
    if (e.op == CF_JAL) return 1;
    if (e.op == CF_JALR) return is_return(e) ? 3 : 2;
    return 0;
  endfunction
  function automatic branch_prediction_t predict(input program_counter_t addr);
    branch_prediction_t value;
    int row, kind;
    value='0;
    row=int'((addr >> 2) % SETS);
    for (int i=0; i<WAYS; i++) begin
      if (table_valid[row*WAYS+i] && (table_pc[row*WAYS+i] >> 2) == (addr >> 2)) begin
        kind=table_kind[row*WAYS+i];
        kind_hits[kind]++;
        value.predicted_taken = kind != 0 || counters[(addr >> 2) % BHT] >= 2;
        value.predicted_target = table_target[row*WAYS+i];
        if (kind == 3 && stack_size != 0) value.predicted_target=stack[stack_size-1];
        if (value.predicted_target[1:0] != 0) value.predicted_taken=0;
      end
    end
    if (!value.predicted_taken) value.predicted_target='0;
    return value;
  endfunction

  task automatic clear_model;
    foreach (counters[i]) counters[i]=1;
    foreach (table_valid[i]) table_valid[i]=0;
    foreach (victim[i]) victim[i]=0;
    stack_size=0; pending='0; expected_valid=0;
  endtask

  task automatic apply_training;
    int row, chosen, history_index;
    bit hit, empty, push, pop;
    // BHT 保留跨 invalidate 的计数，之前保存的训练仍可在本沿完成。
    if (pending.valid && pending.op == CF_BRANCH) begin
      history_index=int'((pending.pc >> 2) % BHT);
      if (pending.taken) begin
        if (counters[history_index] < 3) counters[history_index]++;
        else saturation++;
      end else begin
        if (counters[history_index] > 0) counters[history_index]--;
        else saturation++;
      end
    end
    if (invalidate) begin
      foreach (table_valid[i]) table_valid[i]=0;
      foreach (victim[i]) victim[i]=0;
      stack_size=0; clears++;
    end else if (pending.valid) begin
      updates++;
      row=int'((pending.pc >> 2) % SETS);
      chosen=-1; hit=0; empty=0;
      // 模型先找已有 PC，再找空槽，最后替换，不采用 RTL 的同一循环选择结构。
      for (int i=0; i<WAYS; i++)
        if (table_valid[row*WAYS+i] && (table_pc[row*WAYS+i] >> 2) == (pending.pc >> 2))
          chosen=i;
      hit=chosen>=0;
      if (!hit) begin
        for (int i=WAYS-1; i>=0; i--) if (!table_valid[row*WAYS+i]) chosen=i;
        empty=chosen>=0;
      end
      if (chosen<0) begin chosen=victim[row]; victim[row]=(victim[row]+1)%WAYS; end
      table_valid[row*WAYS+chosen]=1;
      table_pc[row*WAYS+chosen]=pending.pc;
      table_target[row*WAYS+chosen]=pending.target;
      table_kind[row*WAYS+chosen]=classify(pending);
      push=pending.taken && is_link(pending.rd) && (pending.op==CF_JAL || pending.op==CF_JALR);
      pop=pending.taken && is_return(pending);
      if (pop && push) swaps++;
      else if (push) pushes++;
      else if (pop) pops++;
      if (pop && stack_size>0) stack_size--;
      if (push) begin
        if (stack_size==RAS) begin
          for (int i=0; i<RAS-1; i++) stack[i]=stack[i+1];
          stack_size--;
        end
        stack[stack_size]=pending.pc+program_counter_t'(INSTRUCTION_BYTES);
        stack_size++;
      end
    end
    pending='{valid:(train_valid && !invalidate), taken:train_taken, pc:train_pc,
              target:train_target, imm:train_imm, op:train_op, rs1:train_rs1, rd:train_rd};
  endtask

  task automatic check_response;
    assert (response_valid === expected_valid)
      else $fatal(1,"case %0d response valid differs",ID);
    assert (request_ready === ((!expected_valid || response_ready) && !flush))
      else $fatal(1,"case %0d ready differs",ID);
    if (expected_valid) begin
      assert (response_pc===expected_pc && response_epoch===expected_epoch &&
              prediction===expected_prediction && next_pc===
              (expected_prediction.predicted_taken ? expected_prediction.predicted_target :
               expected_pc+program_counter_t'(INSTRUCTION_BYTES)))
        else $fatal(1,"case %0d prediction differs pc=%h expected=%h actual=%h",ID,
                    expected_pc,expected_prediction,prediction);
    end
  endtask

  initial begin
    done_o=0; pc=0; epoch=0; request_valid=0; response_ready=0; flush=0; invalidate=0;
    train_valid=0; train_taken=0; train_pc=0; train_target=0; train_imm=0;
    train_op=CF_NONE; train_rs1=0; train_rd=0;
    clear_model();
    repeat(3) @(negedge clk);
    rst_n=1;
    for (int cycle=0; cycle<12000; cycle++) begin
      // 输入请求在普通反压时保持；flush 可撤销在途查询。
      if (request_ready || !request_valid || flush) begin
        pc=program_counter_t'(32'h80000100 + ((random_state >> 3) % 16)*4);
        epoch=fetch_epoch_t'(random_state >> 20);
        request_valid=random_state[0] || random_state[1];
      end
      random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
      response_ready=random_state[3] || random_state[4];
      flush=cycle%71==70;
      invalidate=cycle%193==192;
      train_valid=1;
      train_pc=program_counter_t'(32'h80000100 + ((random_state >> 4) % 16)*4);
      train_target=program_counter_t'(32'h80001000 + ((random_state >> 10) % 32)*2);
      train_taken=random_state[12]; train_rd=0; train_rs1=0; train_imm=0;
      case(cycle%160)
        // 连续饱和训练，并查询相同 PC。
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15: begin
          train_op=CF_BRANCH; train_pc=32'h80000100; train_taken=cycle%160<8;
          if (request_ready) pc=train_pc;
        end
        default: begin
          case((cycle%160)/24)
            0,1: begin train_op=CF_JAL; train_rd=1; train_taken=1; end
            2: begin train_op=CF_JALR; train_rs1=1; train_taken=1; end
            3: begin train_op=CF_JALR; train_rs1=1; train_rd=5; train_taken=1; end
            4: begin train_op=CF_JALR; train_rs1=10; train_taken=1; end
            default: train_op=CF_BRANCH;
          endcase
        end
      endcase
      #1;
      check_response();
      if (expected_valid && response_ready) responses++;
      if (expected_valid && !response_ready) stalls++;
      if (request_valid && request_ready) begin
        expected_valid=1; expected_pc=pc; expected_epoch=epoch;
        expected_prediction=predict(pc); queries++;
      end else if (response_ready) expected_valid=0;
      if (flush) begin expected_valid=0; flushes++; end
      @(posedge clk);
      apply_training();
      #1;
      check_response();
      @(negedge clk);
      if (cycle==4000 || cycle==8000) begin
        rst_n=0; clear_model();
        repeat(2) @(negedge clk);
        rst_n=1; request_valid=0;
      end
    end
    assert (queries>1000 && responses>1000 && stalls>100 && updates>1000 && clears>20 &&
            flushes>20 && pushes>100 && pops>100 && swaps>100 && saturation>100)
      else $fatal(1,"case %0d insufficient stimulus coverage",ID);
    foreach(kind_hits[i]) assert(kind_hits[i]>5) else $fatal(1,"missing predictor kind %0d",i);
    $display("PASS predictor contract case=%0d BHT=%0d BTB=%0dx%0d RAS=%0d queries=%0d stalls=%0d hits=%p",
             ID,BHT,BTB,WAYS,RAS,queries,stalls,kind_hits);
    done_o=1;
  end
endmodule

module riscv32_predictor_contract_tb;
  wire [4:0] done;
  predictor_contract_case #(.ID(0)) c0(done[0]);
  predictor_contract_case #(.ID(1),.WAYS(1)) c1(done[1]);
  predictor_contract_case #(.ID(2),.WAYS(4)) c2(done[2]);
  predictor_contract_case #(.ID(3),.BHT(2),.BTB(4),.RAS(2)) c3(done[3]);
  predictor_contract_case #(.ID(4),.BHT(64),.BTB(32),.RAS(8)) c4(done[4]);
  initial begin wait(&done); $display("PASS predictor contract: 5 configurations, 60000 cycles"); $finish; end
  initial begin #200000; $fatal(1,"predictor contract timeout"); end
endmodule
