#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {

enum class PredictorKind {
  kSequential,
  kBackwardTakenForwardNotTaken,
  kBimodal,
  kGshare,
};

struct BranchsimConfiguration {
  PredictorKind predictor_kind = PredictorKind::kBimodal;
  uint64_t direction_entry_count = 16;
  uint64_t global_history_bit_count = 4;
  uint64_t target_entry_count = 0;
  uint64_t return_stack_entry_count = 0;
};

struct BranchsimTraceHeader {
  char magic[8];
  uint32_t version;
  uint32_t address_bytes;
  uint64_t instruction_count;
  uint64_t control_flow_count;
};

struct BranchsimControlFlowRecord {
  uint64_t instruction_sequence;
  uint64_t program_counter;
  uint64_t next_program_counter;
  uint32_t instruction;
  uint32_t reserved;
};

struct TargetBufferEntry {
  bool present = false;
  uint64_t program_counter = 0;
  uint64_t target_program_counter = 0;
};

struct BranchsimStatistics {
  uint64_t instruction_count = 0;
  uint64_t control_flow_count = 0;
  uint64_t conditional_branch_count = 0;
  uint64_t conditional_taken_count = 0;
  uint64_t direct_jump_count = 0;
  uint64_t indirect_jump_count = 0;
  uint64_t call_count = 0;
  uint64_t return_count = 0;
  uint64_t conditional_direction_error_count = 0;
  uint64_t direct_jump_error_count = 0;
  uint64_t indirect_target_error_count = 0;
  uint64_t target_buffer_hit_count = 0;
  uint64_t return_stack_prediction_count = 0;
  uint64_t correct_indirect_target_count = 0;
};

constexpr char kBranchsimTraceMagic[8] = {
    'N', 'P', 'C', 'B', 'R', 'T', 'R', '1',
};
constexpr uint32_t kBranchsimTraceVersion = 1;
constexpr uint32_t kConditionalBranchOpcode = 0x63;
constexpr uint32_t kDirectJumpOpcode = 0x6f;
constexpr uint32_t kIndirectJumpOpcode = 0x67;

static_assert(sizeof(BranchsimTraceHeader) == 32);
static_assert(sizeof(BranchsimControlFlowRecord) == 32);

bool IsPowerOfTwo(uint64_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}

uint32_t IntegerLog2(uint64_t value) {
  uint32_t result = 0;
  while (value > 1) {
    value >>= 1;
    ++result;
  }
  return result;
}

int64_t SignExtend(uint64_t value, uint32_t bit_count) {
  const uint64_t sign_bit = uint64_t{1} << (bit_count - 1);
  return static_cast<int64_t>((value ^ sign_bit) - sign_bit);
}

int64_t DecodeConditionalBranchImmediate(uint32_t instruction) {
  const uint64_t immediate =
      ((static_cast<uint64_t>(instruction) >> 31) & 0x1u) << 12 |
      ((static_cast<uint64_t>(instruction) >> 7) & 0x1u) << 11 |
      ((static_cast<uint64_t>(instruction) >> 25) & 0x3fu) << 5 |
      ((static_cast<uint64_t>(instruction) >> 8) & 0xfu) << 1;
  return SignExtend(immediate, 13);
}

int64_t DecodeDirectJumpImmediate(uint32_t instruction) {
  const uint64_t immediate =
      ((static_cast<uint64_t>(instruction) >> 31) & 0x1u) << 20 |
      ((static_cast<uint64_t>(instruction) >> 12) & 0xffu) << 12 |
      ((static_cast<uint64_t>(instruction) >> 20) & 0x1u) << 11 |
      ((static_cast<uint64_t>(instruction) >> 21) & 0x3ffu) << 1;
  return SignExtend(immediate, 21);
}

bool IsLinkRegister(uint32_t register_index) {
  return register_index == 1 || register_index == 5;
}

std::string PredictorName(PredictorKind predictor_kind) {
  switch (predictor_kind) {
    case PredictorKind::kSequential:
      return "sequential";
    case PredictorKind::kBackwardTakenForwardNotTaken:
      return "btfnt";
    case PredictorKind::kBimodal:
      return "bimodal";
    case PredictorKind::kGshare:
      return "gshare";
  }
  throw std::runtime_error("unknown predictor kind");
}

PredictorKind ParsePredictorKind(std::string_view name) {
  if (name == "sequential") {
    return PredictorKind::kSequential;
  }
  if (name == "btfnt") {
    return PredictorKind::kBackwardTakenForwardNotTaken;
  }
  if (name == "bimodal") {
    return PredictorKind::kBimodal;
  }
  if (name == "gshare") {
    return PredictorKind::kGshare;
  }
  throw std::runtime_error("predictor must be sequential, btfnt, bimodal, or gshare");
}

uint64_t ParseUnsigned(std::string_view text, std::string_view option_name) {
  size_t consumed_character_count = 0;
  const std::string owned_text(text);
  const unsigned long long parsed_value =
      std::stoull(owned_text, &consumed_character_count, 0);
  if (consumed_character_count != owned_text.size()) {
    throw std::runtime_error("invalid value for " + std::string(option_name));
  }
  return parsed_value;
}

void ValidateConfiguration(const BranchsimConfiguration &configuration) {
  if ((configuration.predictor_kind == PredictorKind::kBimodal ||
       configuration.predictor_kind == PredictorKind::kGshare) &&
      !IsPowerOfTwo(configuration.direction_entry_count)) {
    throw std::runtime_error("direction entry count must be a nonzero power of two");
  }
  if (configuration.predictor_kind == PredictorKind::kGshare) {
    const uint32_t direction_index_bit_count =
        IntegerLog2(configuration.direction_entry_count);
    if (configuration.global_history_bit_count == 0 ||
        configuration.global_history_bit_count > direction_index_bit_count) {
      throw std::runtime_error(
          "gshare history bits must be between one and log2(direction entries)");
    }
  }
  if (configuration.target_entry_count != 0 &&
      !IsPowerOfTwo(configuration.target_entry_count)) {
    throw std::runtime_error("target entry count must be zero or a power of two");
  }
}

std::vector<BranchsimControlFlowRecord> ReadTrace(
    const std::string &trace_path, BranchsimTraceHeader *header) {
  std::ifstream input(trace_path, std::ios::binary);
  if (!input) {
    throw std::runtime_error("cannot open trace file: " + trace_path);
  }

  input.read(reinterpret_cast<char *>(header), sizeof(*header));
  if (!input || std::memcmp(header->magic, kBranchsimTraceMagic,
                            sizeof(kBranchsimTraceMagic)) != 0) {
    throw std::runtime_error("invalid branchsim trace header");
  }
  if (header->version != kBranchsimTraceVersion) {
    throw std::runtime_error("unsupported branchsim trace version");
  }
  if (header->address_bytes != 4 && header->address_bytes != 8) {
    throw std::runtime_error("unsupported branchsim trace address width");
  }
  if (header->control_flow_count >
      std::numeric_limits<size_t>::max() / sizeof(BranchsimControlFlowRecord)) {
    throw std::runtime_error("branchsim trace is too large for this host");
  }

  std::vector<BranchsimControlFlowRecord> record_array(
      static_cast<size_t>(header->control_flow_count));
  input.read(reinterpret_cast<char *>(record_array.data()),
             static_cast<std::streamsize>(record_array.size() *
                                          sizeof(BranchsimControlFlowRecord)));
  if (!input && !record_array.empty()) {
    throw std::runtime_error("truncated branchsim trace");
  }
  char unexpected_byte = 0;
  if (input.read(&unexpected_byte, 1)) {
    throw std::runtime_error("branchsim trace contains trailing data");
  }
  return record_array;
}

class DirectionPredictor {
 public:
  explicit DirectionPredictor(const BranchsimConfiguration &configuration)
      : configuration_(configuration),
        counter_array_(UsesCounterArray()
                           ? configuration.direction_entry_count
                           : 0,
                       1) {}

  bool Predict(uint64_t program_counter, uint32_t instruction) const {
    switch (configuration_.predictor_kind) {
      case PredictorKind::kSequential:
        return false;
      case PredictorKind::kBackwardTakenForwardNotTaken:
        return DecodeConditionalBranchImmediate(instruction) < 0;
      case PredictorKind::kBimodal:
      case PredictorKind::kGshare:
        return counter_array_[CalculateIndex(program_counter)] >= 2;
    }
    return false;
  }

  void Update(uint64_t program_counter, bool branch_taken) {
    if (UsesCounterArray()) {
      uint8_t &counter = counter_array_[CalculateIndex(program_counter)];
      if (branch_taken) {
        counter = std::min<uint8_t>(3, static_cast<uint8_t>(counter + 1));
      } else {
        counter = counter == 0 ? 0 : static_cast<uint8_t>(counter - 1);
      }
    }

    if (configuration_.predictor_kind == PredictorKind::kGshare) {
      const uint64_t history_mask =
          (uint64_t{1} << configuration_.global_history_bit_count) - 1;
      global_branch_history_ =
          ((global_branch_history_ << 1) | static_cast<uint64_t>(branch_taken)) &
          history_mask;
    }
  }

 private:
  bool UsesCounterArray() const {
    return configuration_.predictor_kind == PredictorKind::kBimodal ||
           configuration_.predictor_kind == PredictorKind::kGshare;
  }

  uint64_t CalculateIndex(uint64_t program_counter) const {
    const uint64_t index_mask = configuration_.direction_entry_count - 1;
    uint64_t index = program_counter >> 2;
    if (configuration_.predictor_kind == PredictorKind::kGshare) {
      index ^= global_branch_history_;
    }
    return index & index_mask;
  }

  BranchsimConfiguration configuration_;
  std::vector<uint8_t> counter_array_;
  uint64_t global_branch_history_ = 0;
};

class IndirectTargetPredictor {
 public:
  explicit IndirectTargetPredictor(const BranchsimConfiguration &configuration)
      : target_buffer_(configuration.target_entry_count),
        return_stack_capacity_(configuration.return_stack_entry_count) {}

  bool Predict(uint64_t program_counter, bool return_stack_pop_requested,
               uint64_t *target_program_counter, bool *used_return_stack,
               bool *target_buffer_hit) const {
    *used_return_stack = false;
    *target_buffer_hit = false;

    if (return_stack_pop_requested && !return_stack_.empty()) {
      *target_program_counter = return_stack_.back();
      *used_return_stack = true;
      return true;
    }
    if (target_buffer_.empty()) {
      return false;
    }

    const TargetBufferEntry &entry =
        target_buffer_[(program_counter >> 2) & (target_buffer_.size() - 1)];
    if (!entry.present || entry.program_counter != program_counter) {
      return false;
    }
    *target_program_counter = entry.target_program_counter;
    *target_buffer_hit = true;
    return true;
  }

  void UpdateTargetBuffer(uint64_t program_counter,
                          uint64_t target_program_counter) {
    if (target_buffer_.empty()) {
      return;
    }
    TargetBufferEntry &entry =
        target_buffer_[(program_counter >> 2) & (target_buffer_.size() - 1)];
    entry.present = true;
    entry.program_counter = program_counter;
    entry.target_program_counter = target_program_counter;
  }

  void UpdateReturnStack(bool pop_requested, bool push_requested,
                         uint64_t return_program_counter) {
    if (pop_requested && !return_stack_.empty()) {
      return_stack_.pop_back();
    }
    if (!push_requested || return_stack_capacity_ == 0) {
      return;
    }
    if (return_stack_.size() == return_stack_capacity_) {
      return_stack_.erase(return_stack_.begin());
    }
    return_stack_.push_back(return_program_counter);
  }

 private:
  std::vector<TargetBufferEntry> target_buffer_;
  uint64_t return_stack_capacity_ = 0;
  std::vector<uint64_t> return_stack_;
};

BranchsimStatistics Simulate(
    const BranchsimTraceHeader &header,
    const std::vector<BranchsimControlFlowRecord> &record_array,
    const BranchsimConfiguration &configuration) {
  BranchsimStatistics statistics;
  statistics.instruction_count = header.instruction_count;
  statistics.control_flow_count = header.control_flow_count;

  DirectionPredictor direction_predictor(configuration);
  IndirectTargetPredictor indirect_target_predictor(configuration);

  for (const BranchsimControlFlowRecord &record : record_array) {
    const uint32_t opcode = record.instruction & 0x7fu;
    const uint64_t sequential_program_counter = record.program_counter + 4;

    if (opcode == kConditionalBranchOpcode) {
      statistics.conditional_branch_count++;
      const bool branch_taken =
          record.next_program_counter != sequential_program_counter;
      statistics.conditional_taken_count += static_cast<uint64_t>(branch_taken);

      const bool predicted_taken =
          direction_predictor.Predict(record.program_counter, record.instruction);
      if (predicted_taken != branch_taken) {
        statistics.conditional_direction_error_count++;
      } else if (predicted_taken) {
        const uint64_t predicted_target = static_cast<uint64_t>(
            static_cast<int64_t>(record.program_counter) +
            DecodeConditionalBranchImmediate(record.instruction));
        if (predicted_target != record.next_program_counter) {
          statistics.conditional_direction_error_count++;
        }
      }
      direction_predictor.Update(record.program_counter, branch_taken);
      continue;
    }

    if (opcode == kDirectJumpOpcode) {
      statistics.direct_jump_count++;
      const uint32_t destination_register = (record.instruction >> 7) & 0x1fu;
      const bool call_occurred = IsLinkRegister(destination_register);
      statistics.call_count += static_cast<uint64_t>(call_occurred);

      if (configuration.predictor_kind == PredictorKind::kSequential) {
        statistics.direct_jump_error_count++;
      } else {
        const uint64_t predicted_target = static_cast<uint64_t>(
            static_cast<int64_t>(record.program_counter) +
            DecodeDirectJumpImmediate(record.instruction));
        if (predicted_target != record.next_program_counter) {
          statistics.direct_jump_error_count++;
        }
      }
      indirect_target_predictor.UpdateReturnStack(
          false, call_occurred, sequential_program_counter);
      continue;
    }

    if (opcode == kIndirectJumpOpcode) {
      statistics.indirect_jump_count++;
      const uint32_t destination_register = (record.instruction >> 7) & 0x1fu;
      const uint32_t source_register = (record.instruction >> 15) & 0x1fu;
      const bool destination_is_link = IsLinkRegister(destination_register);
      const bool source_is_link = IsLinkRegister(source_register);
      const bool return_stack_pop_requested =
          source_is_link && (!destination_is_link ||
                             destination_register != source_register);
      const bool return_stack_push_requested = destination_is_link;
      statistics.call_count +=
          static_cast<uint64_t>(return_stack_push_requested);
      statistics.return_count +=
          static_cast<uint64_t>(return_stack_pop_requested);

      uint64_t predicted_target = 0;
      bool used_return_stack = false;
      bool target_buffer_hit = false;
      const bool target_prediction_present =
          configuration.predictor_kind != PredictorKind::kSequential &&
          indirect_target_predictor.Predict(
              record.program_counter, return_stack_pop_requested,
              &predicted_target, &used_return_stack, &target_buffer_hit);
      statistics.return_stack_prediction_count +=
          static_cast<uint64_t>(used_return_stack);
      statistics.target_buffer_hit_count +=
          static_cast<uint64_t>(target_buffer_hit);
      if (target_prediction_present &&
          predicted_target == record.next_program_counter) {
        statistics.correct_indirect_target_count++;
      } else {
        statistics.indirect_target_error_count++;
      }

      indirect_target_predictor.UpdateTargetBuffer(record.program_counter,
                                                    record.next_program_counter);
      indirect_target_predictor.UpdateReturnStack(
          return_stack_pop_requested, return_stack_push_requested,
          sequential_program_counter);
      continue;
    }

    throw std::runtime_error("branchsim trace contains a non-control-flow opcode");
  }
  return statistics;
}

uint64_t CalculateMispredictionCount(const BranchsimStatistics &statistics) {
  return statistics.conditional_direction_error_count +
         statistics.direct_jump_error_count +
         statistics.indirect_target_error_count;
}

double CalculateRatio(uint64_t numerator, uint64_t denominator) {
  return denominator == 0
             ? 0.0
             : static_cast<double>(numerator) /
                   static_cast<double>(denominator);
}

double EstimateIdealizedIpc(const BranchsimStatistics &statistics,
                            uint32_t issue_width,
                            uint32_t misprediction_penalty_cycles) {
  if (statistics.instruction_count == 0) {
    return 0.0;
  }
  const double ideal_cycle_count =
      static_cast<double>(statistics.instruction_count) / issue_width;
  const double recovery_cycle_count =
      static_cast<double>(CalculateMispredictionCount(statistics)) *
      misprediction_penalty_cycles;
  return static_cast<double>(statistics.instruction_count) /
         (ideal_cycle_count + recovery_cycle_count);
}

uint64_t CalculateStorageBitCount(const BranchsimConfiguration &configuration,
                                  uint32_t address_bit_count) {
  uint64_t bit_count = 0;
  if (configuration.predictor_kind == PredictorKind::kBimodal ||
      configuration.predictor_kind == PredictorKind::kGshare) {
    bit_count += 2 * configuration.direction_entry_count;
  }
  if (configuration.predictor_kind == PredictorKind::kGshare) {
    bit_count += configuration.global_history_bit_count;
  }
  if (configuration.target_entry_count != 0) {
    const uint32_t index_bit_count =
        IntegerLog2(configuration.target_entry_count);
    const uint32_t tag_bit_count = address_bit_count - index_bit_count - 2;
    const uint32_t target_bit_count = address_bit_count - 2;
    bit_count += configuration.target_entry_count *
                 (1 + tag_bit_count + target_bit_count);
  }
  if (configuration.return_stack_entry_count != 0) {
    bit_count += configuration.return_stack_entry_count * address_bit_count;
    bit_count += IntegerLog2(configuration.return_stack_entry_count) + 1;
  }
  return bit_count;
}

void PrintStatistics(const BranchsimStatistics &statistics,
                     const BranchsimConfiguration &configuration,
                     uint32_t address_bit_count) {
  const uint64_t misprediction_count =
      CalculateMispredictionCount(statistics);
  const uint64_t storage_bit_count =
      CalculateStorageBitCount(configuration, address_bit_count);

  std::cout << "Branch predictor statistics\n";
  std::cout << "  predictor                 : "
            << PredictorName(configuration.predictor_kind) << '\n';
  std::cout << "  retired instructions       : "
            << statistics.instruction_count << '\n';
  std::cout << "  control-flow instructions  : "
            << statistics.control_flow_count << '\n';
  std::cout << "  conditional / taken        : "
            << statistics.conditional_branch_count << " / "
            << statistics.conditional_taken_count << '\n';
  std::cout << "  JAL / JALR                 : "
            << statistics.direct_jump_count << " / "
            << statistics.indirect_jump_count << '\n';
  std::cout << "  calls / returns            : " << statistics.call_count
            << " / " << statistics.return_count << '\n';
  std::cout << "  conditional direction errs : "
            << statistics.conditional_direction_error_count << '\n';
  std::cout << "  direct jump errors         : "
            << statistics.direct_jump_error_count << '\n';
  std::cout << "  indirect target errors     : "
            << statistics.indirect_target_error_count << '\n';
  std::cout << "  total mispredictions       : " << misprediction_count
            << '\n';

  std::cout << std::fixed << std::setprecision(6);
  std::cout << "  control-flow accuracy      : "
            << 100.0 * (1.0 - CalculateRatio(
                                  misprediction_count,
                                  statistics.control_flow_count))
            << "%\n";
  std::cout << "  MPKI                       : "
            << 1000.0 * CalculateRatio(misprediction_count,
                                       statistics.instruction_count)
            << '\n';
  std::cout << "  storage estimate           : " << storage_bit_count
            << " bits\n";
  std::cout << "  ideal IPC 5-stage 1-wide   : "
            << EstimateIdealizedIpc(statistics, 1, 2) << '\n';
  std::cout << "  ideal IPC 15-stage 1-wide  : "
            << EstimateIdealizedIpc(statistics, 1, 12) << '\n';
  std::cout << "  ideal IPC 15-stage 4-wide  : "
            << EstimateIdealizedIpc(statistics, 4, 12) << '\n';

  // Stable key=value lines are consumed by explore.py and regression tests.
  std::cout << "predictor=" << PredictorName(configuration.predictor_kind) << '\n';
  std::cout << "direction_entries=" << configuration.direction_entry_count
            << '\n';
  std::cout << "history_bits=" << configuration.global_history_bit_count
            << '\n';
  std::cout << "btb_entries=" << configuration.target_entry_count << '\n';
  std::cout << "ras_entries=" << configuration.return_stack_entry_count << '\n';
  std::cout << "instructions=" << statistics.instruction_count << '\n';
  std::cout << "control_flow=" << statistics.control_flow_count << '\n';
  std::cout << "conditional=" << statistics.conditional_branch_count << '\n';
  std::cout << "conditional_taken=" << statistics.conditional_taken_count
            << '\n';
  std::cout << "jal=" << statistics.direct_jump_count << '\n';
  std::cout << "jalr=" << statistics.indirect_jump_count << '\n';
  std::cout << "calls=" << statistics.call_count << '\n';
  std::cout << "returns=" << statistics.return_count << '\n';
  std::cout << "direction_errors="
            << statistics.conditional_direction_error_count << '\n';
  std::cout << "direct_jump_errors=" << statistics.direct_jump_error_count
            << '\n';
  std::cout << "indirect_target_errors="
            << statistics.indirect_target_error_count << '\n';
  std::cout << "mispredictions=" << misprediction_count << '\n';
  std::cout << "accuracy="
            << 1.0 - CalculateRatio(misprediction_count,
                                    statistics.control_flow_count)
            << '\n';
  std::cout << "mpki="
            << 1000.0 * CalculateRatio(misprediction_count,
                                       statistics.instruction_count)
            << '\n';
  std::cout << "storage_bits=" << storage_bit_count << '\n';
  std::cout << "ipc_5stage_1wide="
            << EstimateIdealizedIpc(statistics, 1, 2) << '\n';
  std::cout << "ipc_15stage_1wide="
            << EstimateIdealizedIpc(statistics, 1, 12) << '\n';
  std::cout << "ipc_15stage_4wide="
            << EstimateIdealizedIpc(statistics, 4, 12) << '\n';
}

void PrintUsage(const char *program_name) {
  std::cerr
      << "Usage: " << program_name
      << " --trace FILE [--predictor sequential|btfnt|bimodal|gshare]"
         " [--direction-entries N] [--history-bits N]"
         " [--btb-entries N] [--ras-entries N]\n";
}

}  // namespace

int main(int argc, char **argv) {
  try {
    std::string trace_path;
    BranchsimConfiguration configuration;

    for (int argument_index = 1; argument_index < argc; ++argument_index) {
      const std::string_view argument(argv[argument_index]);
      if (argument == "--help") {
        PrintUsage(argv[0]);
        return 0;
      }
      if (argument_index + 1 >= argc) {
        throw std::runtime_error("missing value after " + std::string(argument));
      }
      const std::string_view value(argv[++argument_index]);
      if (argument == "--trace") {
        trace_path = value;
      } else if (argument == "--predictor") {
        configuration.predictor_kind = ParsePredictorKind(value);
      } else if (argument == "--direction-entries") {
        configuration.direction_entry_count =
            ParseUnsigned(value, argument);
      } else if (argument == "--history-bits") {
        configuration.global_history_bit_count =
            ParseUnsigned(value, argument);
      } else if (argument == "--btb-entries") {
        configuration.target_entry_count = ParseUnsigned(value, argument);
      } else if (argument == "--ras-entries") {
        configuration.return_stack_entry_count = ParseUnsigned(value, argument);
      } else {
        throw std::runtime_error("unknown option: " + std::string(argument));
      }
    }

    if (trace_path.empty()) {
      throw std::runtime_error("--trace is required");
    }
    ValidateConfiguration(configuration);

    BranchsimTraceHeader header{};
    const std::vector<BranchsimControlFlowRecord> record_array =
        ReadTrace(trace_path, &header);
    const BranchsimStatistics statistics =
        Simulate(header, record_array, configuration);
    PrintStatistics(statistics, configuration, header.address_bytes * 8);
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "branchsim: " << error.what() << '\n';
    return 1;
  }
}
