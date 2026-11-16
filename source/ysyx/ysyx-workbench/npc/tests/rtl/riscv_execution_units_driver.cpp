#include "Vriscv_execution_units_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

struct Operation {
  unsigned operation, word;
  uint64_t a, b, expected;
};
std::vector<Operation> read_vectors(const std::string &path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("Cannot open " + path);
  std::vector<Operation> result;
  Operation value{};
  while (input >> std::hex >> value.operation >> value.word >> value.a >> value.b >> value.expected)
    result.push_back(value);
  if (result.empty()) throw std::runtime_error("Empty vector file " + path);
  return result;
}

class Testbench {
 public:
  VerilatedContext context;
  Vriscv_execution_units_tb dut{&context};
  uint64_t cycle = 0;
  uint64_t random_state = 0x8e52d0714ac963bfULL;
  uint64_t random() {
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;
    return random_state;
  }
  void require(bool condition, const std::string &message) {
    if (!condition) throw std::runtime_error(message + " at cycle " + std::to_string(cycle));
  }
  void settle() { dut.clk_i = 0; dut.eval(); }
  void tick() {
    settle(); context.timeInc(1); dut.clk_i = 1; dut.eval();
    context.timeInc(1); dut.clk_i = 0; dut.eval(); ++cycle;
  }
  void reset() {
    dut.rst_ni = 0; dut.flush_i = 0;
    dut.prediction_error_i = 0; dut.pipeline_request_valid_i = 0;
    dut.pipeline_issue_allowed_i = 0; dut.pipeline_result_ready_i = 0;
    dut.unit_request_valid_i = 0; dut.exu_request_valid_i = 0;
    dut.exu_issue_allowed_i = 0; dut.unit_result_ready_i = 0; dut.exu_result_ready_i = 0;
    tick(); tick(); dut.rst_ni = 1; tick();
  }
  void operands(const Operation &value) {
    dut.operand_a_i = value.a; dut.operand_b_i = value.b;
    dut.unit_operation_i = value.operation; dut.unit_word_i = value.word;
  }
  void alu(const std::vector<Operation> &values) {
    reset();
    for (const auto &value : values) {
      operands(value); dut.alu_operation_i = value.operation; settle();
      require(dut.alu_result_o == value.expected, "ALU independent reference mismatch");
      require(dut.alu_result_o == dut.alu_reference_o, "ALU pre-change RTL mismatch");
    }
    std::cout << "PASS ALU: " << values.size() << " independent and pre-change comparisons\n";
  }
  void branches() {
    reset();
    unsigned count = 0;
    for (unsigned op = 0; op < 4; ++op) for (unsigned condition = 0; condition < 7; ++condition)
      for (unsigned sample = 0; sample < 256; ++sample) {
        const uint64_t a = random(), b = sample % 4 ? random() : a;
        const uint64_t pc = random() & ~uint64_t(3), immediate = random();
        dut.operand_a_i = a; dut.operand_b_i = b; dut.pc_i = pc; dut.immediate_i = immediate;
        dut.branch_operation_i = op; dut.branch_condition_i = condition;
        const uint64_t sign = uint64_t(1) << 63;
        bool compare = false;
        switch (condition) {
          case 1: compare = a == b; break;
          case 2: compare = a != b; break;
          case 3: compare = (a ^ sign) < (b ^ sign); break;
          case 4: compare = (a ^ sign) >= (b ^ sign); break;
          case 5: compare = a < b; break;
          case 6: compare = a >= b; break;
        }
        const bool taken = op == 2 || op == 3 || (op == 1 && compare);
        const uint64_t target = op == 3 ? (a + immediate) & ~uint64_t(1) :
            (op == 1 || op == 2 ? pc + immediate : 0);
        settle();
        require(dut.branch_target_o == target, "Branch target mismatch");
        require(dut.branch_next_pc_o == (taken ? target : pc + 4), "Branch direction mismatch");
        require(bool(dut.branch_misaligned_o) == (taken && (target & 3)), "Branch alignment mismatch");
        ++count;
      }
    std::cout << "PASS branch: " << count << " cases\n";
  }
  void unit(const std::vector<Operation> &all_values, bool divide) {
    reset(); dut.unit_divide_i = divide;
    std::vector<Operation> values;
    for (const auto &value : all_values)
      if ((value.operation >= 4) == divide) values.push_back(value);
    std::deque<Operation> pending;
    std::deque<unsigned> pending_indices;
    size_t issued = 0, completed = 0, cancelled = 0, stalled = 0, turnover = 0;
    bool presenting = false;
    for (uint64_t step = 0; issued < values.size() || !pending.empty(); ++step) {
      require(step < values.size() * 100 + 1000, "Unit timeout");
      const bool flush = step == 31 || step == 77 || step == 257 || step == 1019;
      if (step == 4096) {
        cancelled += pending.size(); pending.clear(); pending_indices.clear(); presenting = false; reset();
        dut.unit_divide_i = divide;
      }
      dut.flush_i = flush;
      if (flush) { cancelled += pending.size(); pending.clear(); pending_indices.clear(); presenting = false; }
      if (!presenting && issued < values.size() && (random() & 7) != 0) presenting = true;
      if (issued < values.size()) operands(values[issued]);
      dut.unit_request_valid_i = presenting && !flush;
      dut.unit_request_index_i = issued % dut.scoreboard_entry_count_o;
      dut.unit_result_ready_i = (random() & 3) != 0 && !(step >= 24 && step < 32);
      settle();
      const bool response = dut.unit_result_valid_o && dut.unit_result_ready_i;
      if (dut.unit_result_valid_o) {
        require(!pending.empty(), "Unit returned an unowned or duplicated result");
        require(dut.unit_result_index_o == pending_indices.front(), "Unit changed transaction identity");
        if (dut.unit_result_o != pending.front().expected) {
          const auto &v = pending.front();
          std::cerr << std::hex << "op=" << v.operation << " word=" << v.word
                    << " a=" << v.a << " b=" << v.b << " expected=" << v.expected
                    << " actual=" << dut.unit_result_o << std::dec << '\n';
          require(false, "Multiply/divide arithmetic mismatch");
        }
        if (response) { pending.pop_front(); pending_indices.pop_front(); ++completed; } else ++stalled;
      }
      const bool request = dut.unit_request_valid_i && dut.unit_request_ready_o;
      if (request) {
        pending_indices.push_back(issued % dut.scoreboard_entry_count_o);
        pending.push_back(values[issued++]); presenting = false;
        if (response) ++turnover;
      }
      tick();
    }
    dut.unit_request_valid_i = 0; dut.flush_i = 0; dut.unit_result_ready_i = 1;
    for (unsigned i = 0; i < 8; ++i) { settle(); require(!dut.unit_result_valid_o, "Late duplicate result"); tick(); }
    require(issued == completed + cancelled, "Unit transaction accounting mismatch");
    require(cancelled != 0 && stalled != 0 && turnover != 0, "Insufficient protocol coverage");
    std::cout << "PASS " << (divide ? "divider" : "multiplier") << ": issued=" << issued
              << " completed=" << completed << " cancelled=" << cancelled << " stalled=" << stalled
              << " same_cycle_turnover=" << turnover << '\n';
  }
  static uint32_t instruction(const Operation &value) {
    return (1u << 25) | (2u << 20) | (1u << 15) | (value.operation << 12) |
           (3u << 7) | (value.word ? 0x3bu : 0x33u);
  }
  void recovery() {
    reset();
    const uint32_t instructions[] = {0x002081b3u, 0x022081b3u, 0x0220c1b3u};
    const uint64_t expected[] = {90, 729, 9};
    for (unsigned index = 0; index < 3; ++index) {
      dut.instruction_i = instructions[index]; dut.pc_i = 0x80000100;
      dut.operand_a_i = 81; dut.operand_b_i = 9;
      dut.prediction_error_i = 1; dut.pipeline_request_valid_i = 1;
      dut.pipeline_issue_allowed_i = 0; dut.pipeline_result_ready_i = 1;
      settle(); require(dut.pipeline_request_ready_o, "Recovery test could not enter empty ID/EX");
      tick(); dut.pipeline_request_valid_i = 0; settle();
      require(dut.pipeline_packet_present_o && dut.pipeline_redirect_valid_o,
              "Prediction correction waited for execution readiness");
      tick();
      for (unsigned wait = 0; wait < 3; ++wait) {
        settle();
        require(dut.pipeline_packet_present_o && !dut.pipeline_redirect_valid_o &&
                !dut.pipeline_result_valid_o, "Early correction lost or reissued blocked instruction");
        tick();
      }
      dut.pipeline_issue_allowed_i = 1; dut.pipeline_result_ready_i = 0;
      dut.operand_a_i = 0; dut.operand_b_i = 0;
      unsigned wait = 0;
      for (; wait < 100; ++wait) {
        settle();
        require(!dut.pipeline_redirect_valid_o, "Held operation repeated correction");
        if (index == 0 || wait == 0)
          require(dut.pipeline_packet_present_o, "Unaccepted operation left ID/EX");
        else
          require(!dut.pipeline_packet_present_o, "Accepted M operation retained ID/EX");
        if (dut.pipeline_result_valid_o) break;
        tick();
      }
      require(wait < 100, "Corrected operation never completed");
      for (unsigned hold = 0; hold < 3; ++hold) {
        settle();
        require(dut.pipeline_result_valid_o && dut.pipeline_result_o == expected[index],
                "Correction or backpressure changed the result");
        tick();
      }
      dut.pipeline_result_ready_i = 1; tick(); settle();
      require(!dut.pipeline_packet_present_o && !dut.pipeline_result_valid_o,
              "Completed corrected instruction was retained");
    }
    // A correction accompanying consumption must discard the same-cycle younger input.
    dut.instruction_i = 0x002081b3u; dut.operand_a_i = 5; dut.operand_b_i = 7;
    dut.pipeline_request_valid_i = 1; dut.pipeline_issue_allowed_i = 1;
    dut.pipeline_result_ready_i = 1; tick(); settle();
    require(dut.pipeline_redirect_valid_o && dut.pipeline_result_valid_o &&
            dut.pipeline_result_o == 12, "Ready ADD did not correct and complete together");
    dut.instruction_i = 0x022081b3u; tick(); dut.pipeline_request_valid_i = 0; settle();
    require(!dut.pipeline_packet_present_o, "Correction retained a wrong-path younger input");
    // An older recovery still cancels an instruction which already corrected the frontend.
    dut.instruction_i = 0x0220c1b3u; dut.operand_a_i = 0x123456789abcdef0ULL;
    dut.operand_b_i = 7; dut.pipeline_request_valid_i = 1;
    dut.pipeline_issue_allowed_i = 1; dut.pipeline_result_ready_i = 0;
    tick(); dut.pipeline_request_valid_i = 0; tick(); dut.flush_i = 1;
    tick(); dut.flush_i = 0; dut.pipeline_result_ready_i = 1;
    for (unsigned wait = 0; wait < 80; ++wait) {
      settle(); require(!dut.pipeline_packet_present_o && !dut.pipeline_result_valid_o,
                        "Older recovery did not cancel corrected division"); tick();
    }
    std::cout << "PASS early recovery: ADD/MUL/DIV held, one correction, backpressure and cancellation\n";
  }

  void latency() {
    // No backpressure: enforce the documented handshake latency, not just arithmetic.
    struct Case { uint64_t dividend; bool word; unsigned cycles; };
    const Case cases[] = {{0, false, 2}, {3, false, 2}, {31, false, 7},
                          {12345, false, 16}, {~uint64_t(0), false, 66},
                          {0x123456780000001fULL, true, 7}};
    for (const auto &sample : cases) {
      reset(); dut.unit_divide_i = 1;
      const uint64_t dividend = sample.word ? uint32_t(sample.dividend) : sample.dividend;
      Operation value{5, unsigned(sample.word), sample.dividend, 7, dividend / 7};
      operands(value); dut.unit_request_index_i = 0;
      dut.unit_request_valid_i = 1; dut.unit_result_ready_i = 1;
      settle(); require(dut.unit_request_ready_o, "Divider not ready after reset");
      const uint64_t issued_cycle = cycle;
      tick(); dut.unit_request_valid_i = 0; settle();
      while (!dut.unit_result_valid_o) {
        require(cycle - issued_cycle <= 66, "Divider latency timeout");
        tick();
      }
      require(cycle - issued_cycle == sample.cycles, "Unexpected divider latency");
      require(dut.unit_result_o == value.expected, "Divider latency case arithmetic mismatch");
      tick();
    }
    // Check input normalization and output sign correction as separate states.
    const Operation signed_cases[] = {
        {4, 0, uint64_t(-31), 7, uint64_t(-4)},
        {4, 0, uint64_t(-31), uint64_t(-7), 4},
        {6, 0, uint64_t(-31), 7, uint64_t(-3)},
        {6, 0, 31, uint64_t(-7), 3}};
    const unsigned signed_cycles[] = {9, 8, 9, 8};
    for (unsigned index = 0; index < 4; ++index) {
      reset(); dut.unit_divide_i = 1; operands(signed_cases[index]);
      dut.unit_request_valid_i = 1; dut.unit_result_ready_i = 1;
      const uint64_t issued_cycle = cycle;
      tick(); dut.unit_request_valid_i = 0;
      while (!dut.unit_result_valid_o) {
        require(cycle - issued_cycle < 10, "Signed divider latency timeout"); tick();
      }
      require(cycle - issued_cycle == signed_cycles[index], "Signed correction latency changed");
      require(dut.unit_result_o == signed_cases[index].expected, "Signed correction result mismatch");
      tick();
    }
    reset(); dut.unit_divide_i = 0;
    operands(Operation{0, 0, 3, 7, 21});
    dut.unit_request_valid_i = 1; dut.unit_result_ready_i = 1;
    const uint64_t issued_cycle = cycle;
    tick(); dut.unit_request_valid_i = 0;
    while (!dut.unit_result_valid_o) { require(cycle - issued_cycle < 4, "Multiplier latency timeout"); tick(); }
    require(cycle - issued_cycle == 3 && dut.unit_result_o == 21, "Multiplier latency changed");
    tick();
    std::cout << "PASS FU latency: MUL=3, DIVU 31/7=7, 12345/7=16, full-width=66; negative DIV/REM 31/7=9 cycles\n";
  }

  void execution(const std::vector<Operation> &values) {
    reset(); size_t completed = 0, blocked = 0, cancelled = 0;
    bool outstanding = false;
    for (uint64_t step = 0; completed < values.size(); ++step) {
      require(step < values.size() * 150 + 1000, "EXU timeout");
      if (step == 1003) { reset(); outstanding = false; ++cancelled; }
      const auto &value = values[completed]; operands(value);
      dut.instruction_i = instruction(value); dut.pc_i = 0x80000100;
      dut.exu_request_index_i = completed % dut.scoreboard_entry_count_o;
      dut.flush_i = step == 31 || step == 509 || step == 2039;
      if (dut.flush_i) { ++cancelled; outstanding = false; }
      dut.exu_request_valid_i = !outstanding && !dut.flush_i;
      dut.exu_issue_allowed_i = !dut.flush_i && (random() & 7) != 0;
      dut.exu_result_ready_i = (random() & 3) != 0;
      settle();
      require(!dut.decode_exception_o && dut.decode_fu_o == 6 &&
              dut.decode_operation_o == value.operation && dut.decode_word_o == value.word,
              "M instruction decoded incorrectly");
      if (!dut.exu_issue_allowed_i) ++blocked;
      const bool request = dut.exu_request_valid_i && dut.exu_issue_allowed_i && dut.exu_request_ready_o;
      const bool response = dut.exu_result_valid_o && dut.exu_result_ready_i;
      if (dut.exu_result_valid_o) {
        require(outstanding, "EXU result has no accepted request");
        require(dut.exu_result_index_o == completed % dut.scoreboard_entry_count_o, "EXU transaction identity changed");
        require(!dut.exu_exception_o && dut.exu_result_o == value.expected, "EXU result mismatch");
        require(dut.exu_forwardable_o, "Completed M result unavailable for forwarding");
      }
      tick();
      if (request) outstanding = true;
      if (response) { ++completed; outstanding = false; }
    }
    dut.exu_request_valid_i = 0; dut.exu_issue_allowed_i = 1; dut.exu_result_ready_i = 1;
    for (unsigned i = 0; i < 80; ++i) { settle(); require(!dut.exu_result_valid_o, "EXU duplicate completion"); tick(); }
    for (unsigned op : {1u, 2u, 3u}) {
      Operation invalid{op, 1, 0, 0, 0}; dut.instruction_i = instruction(invalid); settle();
      require(dut.decode_exception_o, "Reserved OP-32 multiply encoding accepted");
    }
    std::cout << "PASS IDU/EXU: completed=" << completed << " blocked=" << blocked
              << " cancellation_events=" << cancelled << '\n';
  }
};
int main(int argc, char **argv) {
  try {
    if (argc != 3) throw std::runtime_error("Expected ALU and multiply/divide vector paths");
    Testbench test; test.context.commandArgs(argc, argv);
    const auto alu = read_vectors(argv[1]); const auto muldiv = read_vectors(argv[2]);
    test.alu(alu); test.branches(); test.unit(muldiv, false); test.unit(muldiv, true);
    test.execution(muldiv); test.recovery(); test.latency(); test.dut.final();
    std::cout << "PASS execution units: total_cycles=" << test.cycle << '\n';
    return 0;
  } catch (const std::exception &error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
