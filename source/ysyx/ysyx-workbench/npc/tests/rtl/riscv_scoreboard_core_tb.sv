module riscv_scoreboard_core_tb;
  import riscv_config_pkg::*;
  import riscv_pkg::*;
  import riscv_axi4_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = !clk;
  axi4_manager_to_target_t instruction_request, data_request;
  axi4_target_to_manager_t instruction_response, data_response;
  riscv_core #(
      .RESET_PC(64'h80000000)
  ) dut (
      .clk_i(clk),
      .rst_ni(rst_n),
      .instruction_axi4_manager_o(instruction_request),
      .instruction_axi4_manager_i(instruction_response),
      .data_axi4_manager_o(data_request),
      .data_axi4_manager_i(data_response)
  );
  instruction_t program_array[256];
  xlen_data_t expected_value_array[256];
  logic expected_write_array[256];
  logic [63:0] expected_pc = 64'h80000000;
  axi4_read_address_t instruction_address;
  logic read_present = 0;
  int beat = 0;
  int mode = 0;
  int cycle = 0;
  int commits = 0;
  int full_cycles = 0;
  int younger_normal_completions = 0;
  int younger_multiply_completions = 0;
  int branch_while_dividing = 0;
  int young_divisions = 0;
  int traps = 0;
  int memory_completions_before_divide = 0;
  int memory_requests = 0;
  int memory_requests_before_retirement = 0;
  logic first_memory_retired = 0;
  logic data_read_present = 0;
  logic write_address_present = 0;
  logic write_data_present = 0;
  axi4_read_address_t data_address;
  axi4_write_address_t write_address;
  xlen_data_t memory_value = 64'h123;
  int finish_index;
  logic first_divide_issued = 0;
  logic first_divide_completed = 0;
  localparam logic [63:0] QUOTIENT = 64'h2492492492492492;

  function automatic instruction_t addi(input int rd, rs1, immediate);
    return (32'(immediate) << 20) | (32'(rs1) << 15) | (32'(rd) << 7) | 32'h13;
  endfunction
  function automatic instruction_t reg_op(input int rd, rs1, rs2, funct3, funct7);
    return (32'(funct7) << 25) | (32'(rs2) << 20) | (32'(rs1) << 15) |
        (32'(funct3) << 12) | (32'(rd) << 7) | 32'h33;
  endfunction
  task automatic emit(input int index, input instruction_t instruction, input logic writes,
                      input xlen_data_t value);
    program_array[index]        = instruction;
    expected_value_array[index] = value;
    expected_write_array[index] = writes;
  endtask
  function automatic instruction_t instruction_word(input logic [31:0] address);
    if (address >= 32'h80000000 && address < 32'h80000400)
      return program_array[(address-32'h80000000)>>2];
    return 32'h00000013;
  endfunction

  always_comb begin
    instruction_response          = '0;
    instruction_response.ar_ready = !read_present;
    instruction_response.r_valid  = read_present;
    instruction_response.r.id     = instruction_address.id;
    instruction_response.r.last   = beat == int'(instruction_address.len);
    instruction_response.r.resp   = AXI4_RESP_OKAY;
    for (int lane = 0; lane < MEM_AXI_DATA_BYTE_COUNT / 4; lane++)
    instruction_response.r.data[lane*32+:32] = instruction_word(((instruction_address.addr + (32'(beat) << instruction_address.size)) &
           ~32'(MEM_AXI_DATA_BYTE_COUNT-1)) + 32'(lane*4));
    data_response                            = '0;
    data_response.ar_ready                   = !data_read_present;
    data_response.r_valid                    = data_read_present;
    data_response.r.id                       = data_address.id;
    data_response.r.last                     = 1;
    data_response.r.resp                     = mode == 6 ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
    data_response.r.data                     = memory_value;
    data_response.aw_ready                   = !write_address_present;
    data_response.w_ready                    = write_address_present && !write_data_present;
    data_response.b_valid                    = write_address_present && write_data_present;
    data_response.b.id                       = write_address.id;
    data_response.b.resp                     = AXI4_RESP_OKAY;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cycle <= cycle + 1;
      if (instruction_request.ar_valid && instruction_response.ar_ready) begin
        instruction_address <= instruction_request.ar;
        read_present        <= 1;
        beat                <= 0;
      end
      if (instruction_response.r_valid && instruction_request.r_ready) begin
        if (instruction_response.r.last) read_present <= 0;
        else beat <= beat + 1;
      end
      if (mode != 5 && mode != 6) begin
        assert (!data_request.ar_valid && !data_request.aw_valid && !data_request.w_valid)
        else $fatal(1, "Wrong-path memory operation reached AXI");
        assert (!(dut.lsu_req_valid && dut.lsu_req_ready))
        else $fatal(1, "Wrong-path memory operation entered LSU");
      end
      if (data_request.ar_valid && data_response.ar_ready) begin
        data_address      <= data_request.ar;
        data_read_present <= 1;
      end
      if (data_response.r_valid && data_request.r_ready) data_read_present <= 0;
      if (data_request.aw_valid && data_response.aw_ready) begin
        write_address         <= data_request.aw;
        write_address_present <= 1;
      end
      if (data_request.w_valid && data_response.w_ready) begin
        write_data_present <= 1;
        assert (data_request.w.strb == '1 && data_request.w.last)
        else $fatal(1, "Unexpected store mask or length");
        memory_value <= data_request.w.data;
      end
      if (data_response.b_valid && data_request.b_ready) begin
        write_address_present <= 0;
        write_data_present    <= 0;
      end
      if (dut.lsu_req_valid && dut.lsu_req_ready) begin
        if (!first_memory_retired)
          memory_requests_before_retirement <= memory_requests_before_retirement + 1;
        if (mode == 6)
          assert (memory_requests == 0)
          else $fatal(1, "A younger memory operation followed a faulting load");
        memory_requests <= memory_requests + 1;
      end
      if (dut.lsu_writeback_valid && !first_divide_completed)
        memory_completions_before_divide <= memory_completions_before_divide + 1;
      if (!dut.scoreboard_allocate_ready) full_cycles <= full_cycles + 1;
      if (dut.execute_handshake && dut.execute_packet.uop.pc == 64'h80000018)
        first_divide_issued <= 1;
      if (dut.divide_result_valid && !first_divide_completed) first_divide_completed <= 1;
      if (first_divide_issued && !first_divide_completed) begin
        if (dut.resolved_execute_result_valid)
          younger_normal_completions <= younger_normal_completions + 1;
        if (dut.multiply_result_valid)
          younger_multiply_completions <= younger_multiply_completions + 1;
        if (dut.execute_redirect_resolution_event)
          branch_while_dividing <= branch_while_dividing + 1;
      end
      if (mode == 1 && dut.execute_handshake && dut.execute_packet.uop.pc == 64'h80000024)
        young_divisions <= young_divisions + 1;
      if (mode == 3 && dut.execute_handshake && dut.execute_packet.uop.pc == 64'h80000020)
        assert (first_divide_completed || dut.divide_result_valid)
        else $fatal(1, "Younger ready instruction skipped an unissued dependent instruction");
      if (dut.commit_valid) begin
        int index;
        index = int'((dut.commit.pc - 64'h80000000) >> 2);
        assert (dut.commit.pc == expected_pc && dut.commit.instruction == program_array[index])
        else
          $fatal(
              1, "Commit identity/order mismatch: pc=%h expected=%h", dut.commit.pc, expected_pc
          );
        if ((mode == 1 || mode == 6) && index == 7) begin
          assert (dut.commit.trap_taken && dut.commit.trap_cause_code == (mode == 6 ? 5 : 2) && !dut.commit.gpr_write)
          else $fatal(1, "Old illegal instruction did not trap precisely");
          if (mode == 6)
            assert (dut.commit.trap_tval == 64'h0f000000 && !dut.commit.memory_access)
            else $fatal(1, "Faulting load lost precise exception metadata");
          traps       <= traps + 1;
          expected_pc <= 64'h80000080;
        end else begin
          assert (!dut.commit.trap_taken && dut.commit.gpr_write == expected_write_array[index])
          else $fatal(1, "Unexpected trap or register write at pc=%h", dut.commit.pc);
          if (expected_write_array[index]) begin
            assert (dut.commit.gpr_addr == program_array[index][11:7] &&
                    dut.commit.gpr_wdata == expected_value_array[index])
            else
              $fatal(
                  1,
                  "Register result mismatch pc=%h rd=%0d actual=%h expected=%h",
                  dut.commit.pc,
                  dut.commit.gpr_addr,
                  dut.commit.gpr_wdata,
                  expected_value_array[index]
              );
          end
          expected_pc <= (mode == 0 && index == 9) ? 64'h80000030 : dut.commit.pc + 4;
        end
        if (mode == 5 && (index == 7 || index == 8 || index == 9)) begin
          assert (dut.commit.memory_access && dut.commit.memory_addr == 64'h0f000000 &&
                  dut.commit.memory_size == MEM_SIZE_DOUBLE)
          else $fatal(1, "Completed memory instruction lost its retirement identity");
          if (index == 8)
            assert (dut.commit.memory_cmd == MEM_CMD_STORE &&
                    dut.commit.memory_wdata == 77 && dut.commit.memory_wmask == '1)
            else $fatal(1, "Store retirement data overwritten by younger memory");
          else
            assert (dut.commit.memory_cmd == MEM_CMD_LOAD &&
                    dut.commit.memory_rdata == (index == 7 ? 64'h123 : 64'd77))
            else $fatal(1, "Load retirement data overwritten by younger memory");
          if (index == 7) first_memory_retired <= 1;
        end
        commits <= commits + 1;
        if (index == finish_index) begin
          if (mode == 0)
            assert (younger_normal_completions > 0 && younger_multiply_completions > 0 && branch_while_dividing > 0)
            else $fatal(1, "No observed overlap or branch recovery around older DIV");
          if (mode == 1)
            assert (traps == 1 && young_divisions == 1 && younger_multiply_completions > 0)
            else $fatal(1, "No younger in-flight DIV cancellation or completed MUL at trap");
          if (mode == 2)
            assert (full_cycles > 0)
            else $fatal(1, "Queue-full coverage missing");
          if (mode == 4)
            assert (younger_normal_completions > 0 && younger_multiply_completions > 0)
            else $fatal(1, "Same-rd writers failed to overlap older DIV");
          if (mode == 5)
            assert (memory_completions_before_divide == 3 && memory_requests_before_retirement == 3 &&
                    memory_requests == 3 && memory_value == 77)
            else $fatal(1, "Memory did not overlap DIV or preserve ordered side effects");
          if (mode == 6)
            assert (traps == 1 && memory_requests == 1 && memory_value == 64'h123)
            else $fatal(1, "Faulting LSU allowed a younger store or failed to trap");
          $display("Memory completions before DIV: %0d; requests: %0d",
                   memory_completions_before_divide, memory_requests);
          $display(
              "PASS scoreboard core mode=%0d cycles=%0d commits=%0d normal_before_div=%0d mul_before_div=%0d branch_before_div=%0d full_cycles=%0d cancelled_div=%0d",
              mode, cycle, commits + 1, younger_normal_completions, younger_multiply_completions,
              branch_while_dividing, full_cycles, young_divisions);
          $finish;
        end
      end
      if (cycle > 10000) $fatal(1, "Core scoreboard test timeout");
    end
  end

  initial begin
    if (!$value$plusargs("mode=%d", mode)) mode = 0;
    for (int i = 0; i < 256; i++) begin
      program_array[i]        = 32'h00000013;
      expected_value_array[i] = 0;
      expected_write_array[i] = 0;
    end
    emit(0, addi(1, 0, -1), 1, '1);
    emit(1, addi(2, 0, 7), 1, 7);
    emit(2, addi(3, 0, 11), 1, 11);
    emit(3, 32'h00000517, 1, 64'h8000000c);  // auipc x10,0
    emit(4, addi(10, 10, 116), 1, 64'h80000080);
    emit(5, 32'h30551073, 0, 0);  // csrrw x0,mtvec,x10
    emit(6, reg_op(5, 1, 2, 5, 1), 1, QUOTIENT);
    case (mode)
      0: begin
        emit(7, addi(6, 3, 9), 1, 20);
        emit(8, reg_op(7, 3, 2, 0, 1), 1, 77);
        emit(9, 32'h00000663, 0, 0);  // beq x0,x0,+12; fits with older DIV in four slots
        emit(10, 32'h00103023, 0, 0);  // wrong-path sd x1,0(x0)
        emit(11, reg_op(9, 1, 2, 5, 1), 1, QUOTIENT);
        emit(12, reg_op(8, 7, 6, 0, 0), 1, 97);
        emit(13, addi(9, 8, 1), 1, 98);
        emit(14, reg_op(11, 5, 9, 0, 0), 1, QUOTIENT + 98);
        finish_index = 15;
      end
      1: begin
        emit(7, 32'hffffffff, 0, 0);
        emit(8, reg_op(7, 3, 2, 0, 1), 1, 77);
        emit(9, reg_op(8, 1, 2, 5, 1), 1, QUOTIENT);
        emit(10, 32'h00103023, 0, 0);
        emit(32, addi(15, 0, 1), 1, 1);
        emit(33, reg_op(16, 1, 2, 5, 1), 1, QUOTIENT);
        emit(34, reg_op(17, 3, 2, 0, 0), 1, 18);
        finish_index = 35;
      end
      2: begin
        for (int i = 7; i < 24; i++) emit(i, addi(i, 3, i), 1, 64'(11 + i));
        finish_index = 24;
      end
      3: begin
        emit(7, reg_op(6, 5, 3, 0, 0), 1, QUOTIENT + 11);
        emit(8, reg_op(7, 3, 2, 0, 0), 1, 18);
        finish_index = 9;
      end
      4: begin
        emit(7, addi(5, 3, 9), 1, 20);
        emit(8, reg_op(5, 3, 2, 0, 1), 1, 77);
        emit(9, addi(6, 5, 1), 1, 78);
        for (int i = 10; i < 30; i++) emit(i, addi(5, 5, 1), 1, 64'(77 + i - 9));
        emit(30, addi(7, 6, 1), 1, 79);
        finish_index = 31;
      end
      5: begin
        emit(3, 32'h0f000637, 1, 64'h0f000000);
        emit(4, addi(10, 0, 0), 1, 0);
        emit(6, reg_op(5, 1, 2, 5, 1), 1, QUOTIENT);
        emit(7, 32'h00063403, 1, 64'h123);  // ld x8,0(x12)
        emit(2, addi(7, 0, 77), 1, 77);
        emit(8, 32'h00763023, 0, 0);  // sd x7,0(x12)
        emit(9, 32'h00063483, 1, 77);  // ld x9,0(x12)
        finish_index = 10;
      end
      6: begin
        emit(2, 32'h0f000637, 1, 64'h0f000000);  // lui x12,0x0f000
        emit(7, 32'h00063403, 0, 0);             // faulting ld x8,0(x12)
        emit(8, 32'h00163023, 0, 0);             // younger sd must never issue
        emit(32, addi(15, 0, 1), 1, 1);
        finish_index = 33;
      end
      default: $fatal(1, "Invalid mode");
    endcase
    emit(finish_index, addi(12, 0, 1), 1, 1);
    repeat (4) @(negedge clk);
    rst_n = 1;
  end
endmodule
