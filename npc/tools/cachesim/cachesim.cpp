#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <list>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

enum class RefillTransportModel {
  kFixedPenalty,
  kIndependentReadTransactions,
  kIncrementingBurst,
};

enum class TraceKind {
  kInstruction,
  kData,
};

struct CacheConfiguration {
  uint64_t capacity_bytes = 8192;
  uint64_t line_bytes = 32;
  uint64_t way_count = 2;
  uint64_t refill_beat_bytes = 4;
  double hit_time_cycles = 2.0;
  double critical_response_penalty_cycles = 0.0;
  double complete_refill_penalty_cycles = 0.0;
  double dirty_writeback_penalty_cycles = 0.0;
  double read_address_cycles = 1.0;
  double memory_command_cycles = 1.0;
  double first_data_cycles = 1.0;
  double response_beat_cycles = 1.0;
  double write_address_cycles = 1.0;
  double write_data_beat_cycles = 1.0;
  double write_response_cycles = 1.0;
  RefillTransportModel refill_transport_model =
      RefillTransportModel::kFixedPenalty;
};

struct CacheStatistics {
  TraceKind trace_kind = TraceKind::kInstruction;
  uint64_t architectural_access_count = 0;
  uint64_t load_access_count = 0;
  uint64_t store_access_count = 0;
  uint64_t access_count = 0;
  uint64_t hit_count = 0;
  uint64_t miss_count = 0;
  uint64_t compulsory_miss_count = 0;
  uint64_t capacity_miss_count = 0;
  uint64_t conflict_miss_count = 0;
  uint64_t unique_line_count = 0;
  uint64_t critical_beat_position_sum = 0;
  uint64_t source_line_count = 0;
  uint64_t ignored_nonempty_line_count = 0;
  uint64_t dirty_eviction_count = 0;
};

struct RefillStatistics {
  uint64_t refill_beat_count_per_line = 0;
  uint64_t read_transaction_count = 0;
  uint64_t transferred_beat_count = 0;
  double average_critical_beat_position = 0.0;
  double average_critical_response_penalty_cycles = 0.0;
  double average_complete_refill_penalty_cycles = 0.0;
  double average_dirty_writeback_penalty_cycles = 0.0;
  double total_critical_miss_time_cycles = 0.0;
  double total_refill_occupancy_cycles = 0.0;
  double total_dirty_writeback_cycles = 0.0;
};

struct CacheLine {
  bool present = false;
  bool dirty = false;
  uint64_t tag = 0;
  uint64_t last_access_sequence = 0;
};

struct CacheAccessResult {
  bool hit = false;
  bool dirty_eviction_occurred = false;
};

struct BinaryTraceHeader {
  char magic[8];
  uint32_t version;
  uint32_t address_bytes;
  uint64_t access_count;
  uint64_t run_count;
};

struct BinaryProgramCounterRun {
  uint64_t first_program_counter;
  uint32_t instruction_count;
  int32_t program_counter_stride_bytes;
};

struct BinaryDataAccessRun {
  uint64_t first_address;
  uint32_t access_count;
  int16_t address_stride_bytes;
  uint8_t transfer_byte_count;
  uint8_t flags;
};

enum : uint8_t {
  kDataAccessWrite = 1u << 0,
};

constexpr char kBinaryTraceMagic[8] = {
    'N', 'P', 'C', 'P', 'C', 'T', 'R', '1',
};
constexpr char kBinaryDataTraceMagic[8] = {
    'N', 'P', 'C', 'D', 'C', 'T', 'R', '1',
};
constexpr uint32_t kBinaryTraceVersion = 1;

static_assert(sizeof(BinaryTraceHeader) == 32);
static_assert(sizeof(BinaryProgramCounterRun) == 16);
static_assert(sizeof(BinaryDataAccessRun) == 16);

class SetAssociativeCache {
 public:
  explicit SetAssociativeCache(const CacheConfiguration &configuration)
      : way_count_(configuration.way_count),
        set_count_(configuration.capacity_bytes /
                   (configuration.line_bytes * configuration.way_count)),
        set_array_(set_count_, std::vector<CacheLine>(way_count_)) {}

  CacheAccessResult Access(uint64_t block_address, bool is_write) {
    ++access_sequence_;

    const uint64_t set_index = block_address % set_count_;
    const uint64_t tag = block_address / set_count_;
    std::vector<CacheLine> &set = set_array_[set_index];

    for (CacheLine &line : set) {
      if (line.present && line.tag == tag) {
        line.dirty = line.dirty || is_write;
        line.last_access_sequence = access_sequence_;
        return CacheAccessResult{true, false};
      }
    }

    CacheLine *replacement_line = nullptr;
    for (CacheLine &line : set) {
      if (!line.present) {
        replacement_line = &line;
        break;
      }
    }

    if (replacement_line == nullptr) {
      replacement_line = &*std::min_element(
          set.begin(), set.end(), [](const CacheLine &left, const CacheLine &right) {
            return left.last_access_sequence < right.last_access_sequence;
          });
    }

    const bool dirty_eviction_occurred =
        replacement_line->present && replacement_line->dirty;
    replacement_line->present = true;
    replacement_line->dirty = is_write;
    replacement_line->tag = tag;
    replacement_line->last_access_sequence = access_sequence_;
    return CacheAccessResult{false, dirty_eviction_occurred};
  }

  uint64_t set_count() const { return set_count_; }

 private:
  uint64_t way_count_;
  uint64_t set_count_;
  uint64_t access_sequence_ = 0;
  std::vector<std::vector<CacheLine>> set_array_;
};

// The fully associative cache has the same line count as the tested cache.
// Its LRU result separates capacity misses from set-mapping conflict misses.
class FullyAssociativeShadowCache {
 public:
  explicit FullyAssociativeShadowCache(uint64_t line_count)
      : line_count_(line_count) {}

  bool Access(uint64_t block_address) {
    const auto present_line = line_position_by_block_address_.find(block_address);
    if (present_line != line_position_by_block_address_.end()) {
      lru_block_address_list_.splice(lru_block_address_list_.begin(),
                                     lru_block_address_list_,
                                     present_line->second);
      present_line->second = lru_block_address_list_.begin();
      return true;
    }

    if (lru_block_address_list_.size() == line_count_) {
      const uint64_t replaced_block_address = lru_block_address_list_.back();
      line_position_by_block_address_.erase(replaced_block_address);
      lru_block_address_list_.pop_back();
    }
    lru_block_address_list_.push_front(block_address);
    line_position_by_block_address_[block_address] =
        lru_block_address_list_.begin();
    return false;
  }

 private:
  uint64_t line_count_;
  std::list<uint64_t> lru_block_address_list_;
  std::unordered_map<uint64_t, std::list<uint64_t>::iterator>
      line_position_by_block_address_;
};

bool IsPowerOfTwo(uint64_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}

void ValidateConfiguration(const CacheConfiguration &configuration) {
  if (!IsPowerOfTwo(configuration.capacity_bytes)) {
    throw std::runtime_error("capacity must be a nonzero power of two");
  }
  if (!IsPowerOfTwo(configuration.line_bytes)) {
    throw std::runtime_error("line size must be a nonzero power of two");
  }
  if (!IsPowerOfTwo(configuration.way_count)) {
    throw std::runtime_error("way count must be a nonzero power of two");
  }
  if (!IsPowerOfTwo(configuration.refill_beat_bytes)) {
    throw std::runtime_error("refill beat size must be a nonzero power of two");
  }
  if (configuration.line_bytes < configuration.refill_beat_bytes ||
      configuration.line_bytes % configuration.refill_beat_bytes != 0) {
    throw std::runtime_error(
        "line size must be divisible by the refill beat size");
  }
  if (configuration.capacity_bytes <
      configuration.line_bytes * configuration.way_count) {
    throw std::runtime_error("capacity is smaller than one complete cache set");
  }
  if (configuration.capacity_bytes %
          (configuration.line_bytes * configuration.way_count) !=
      0) {
    throw std::runtime_error("capacity must be divisible by line size times way count");
  }
  if (!std::isfinite(configuration.hit_time_cycles) ||
      configuration.hit_time_cycles < 0.0) {
    throw std::runtime_error("hit time must be a finite nonnegative number");
  }
  if (!std::isfinite(configuration.critical_response_penalty_cycles) ||
      configuration.critical_response_penalty_cycles < 0.0) {
    throw std::runtime_error(
        "critical response penalty must be a finite nonnegative number");
  }
  if (!std::isfinite(configuration.complete_refill_penalty_cycles) ||
      configuration.complete_refill_penalty_cycles < 0.0) {
    throw std::runtime_error(
        "complete refill penalty must be a finite nonnegative number");
  }
  if (!std::isfinite(configuration.dirty_writeback_penalty_cycles) ||
      configuration.dirty_writeback_penalty_cycles < 0.0) {
    throw std::runtime_error(
        "dirty writeback penalty must be a finite nonnegative number");
  }
  const double refill_phase_cycles[] = {
      configuration.read_address_cycles,
      configuration.memory_command_cycles,
      configuration.first_data_cycles,
      configuration.response_beat_cycles,
      configuration.write_address_cycles,
      configuration.write_data_beat_cycles,
      configuration.write_response_cycles,
  };
  for (const double phase_cycles : refill_phase_cycles) {
    if (!std::isfinite(phase_cycles) || phase_cycles < 0.0) {
      throw std::runtime_error(
          "refill phase times must be finite nonnegative numbers");
    }
  }
}

const char *RefillTransportModelName(RefillTransportModel model) {
  switch (model) {
    case RefillTransportModel::kFixedPenalty:
      return "fixed";
    case RefillTransportModel::kIndependentReadTransactions:
      return "independent";
    case RefillTransportModel::kIncrementingBurst:
      return "burst";
  }
  throw std::runtime_error("unreachable refill transport model");
}

const char *TraceKindName(TraceKind trace_kind) {
  return trace_kind == TraceKind::kInstruction ? "instruction" : "data";
}

RefillTransportModel ParseRefillTransportModel(const std::string &text) {
  if (text == "fixed") {
    return RefillTransportModel::kFixedPenalty;
  }
  if (text == "independent") {
    return RefillTransportModel::kIndependentReadTransactions;
  }
  if (text == "burst") {
    return RefillTransportModel::kIncrementingBurst;
  }
  throw std::runtime_error(
      "--refill-model must be fixed, independent, or burst");
}

std::string_view TrimLeft(std::string_view text) {
  const size_t first = text.find_first_not_of(" \t\r\n");
  return first == std::string_view::npos ? std::string_view{} : text.substr(first);
}

// Accepted inputs:
//   0x80000000
//   0x80000000: 00000513  ...       (NEMU log)
//   itrace: 0x80000000: 00000513 ... (NPC text trace)
std::optional<uint64_t> ParseProgramCounter(std::string_view line) {
  line = TrimLeft(line);
  constexpr std::string_view kNpcPrefix = "itrace:";
  if (line.substr(0, kNpcPrefix.size()) == kNpcPrefix) {
    line = TrimLeft(line.substr(kNpcPrefix.size()));
  }

  if (line.size() < 3 || line[0] != '0' || (line[1] != 'x' && line[1] != 'X')) {
    return std::nullopt;
  }

  const char *hex_begin = line.data() + 2;
  const char *hex_end = hex_begin;
  while (hex_end != line.data() + line.size()) {
    const char character = *hex_end;
    const bool is_hex_digit =
        (character >= '0' && character <= '9') ||
        (character >= 'a' && character <= 'f') ||
        (character >= 'A' && character <= 'F');
    if (!is_hex_digit) {
      break;
    }
    ++hex_end;
  }

  if (hex_end == hex_begin) {
    return std::nullopt;
  }
  if (hex_end != line.data() + line.size() && *hex_end != ':' && *hex_end != ' ' &&
      *hex_end != '\t' && *hex_end != '\r') {
    return std::nullopt;
  }

  uint64_t program_counter = 0;
  const std::from_chars_result result =
      std::from_chars(hex_begin, hex_end, program_counter, 16);
  if (result.ec != std::errc{} || result.ptr != hex_end) {
    return std::nullopt;
  }
  return program_counter;
}

uint64_t ParseUnsignedInteger(const std::string &text, const char *option_name) {
  size_t parsed_character_count = 0;
  uint64_t value = 0;
  try {
    value = std::stoull(text, &parsed_character_count, 0);
  } catch (const std::exception &) {
    throw std::runtime_error(std::string("invalid value for ") + option_name +
                             ": " + text);
  }
  if (parsed_character_count != text.size()) {
    throw std::runtime_error(std::string("invalid value for ") + option_name +
                             ": " + text);
  }
  return value;
}

double ParseFloatingPoint(const std::string &text, const char *option_name) {
  size_t parsed_character_count = 0;
  double value = 0.0;
  try {
    value = std::stod(text, &parsed_character_count);
  } catch (const std::exception &) {
    throw std::runtime_error(std::string("invalid value for ") + option_name +
                             ": " + text);
  }
  if (parsed_character_count != text.size()) {
    throw std::runtime_error(std::string("invalid value for ") + option_name +
                             ": " + text);
  }
  return value;
}

struct CommandLineOptions {
  CacheConfiguration configuration;
  std::string trace_path;
  std::string output_format = "text";
};

void PrintUsage(const char *program_name) {
  std::cout
      << "Usage: " << program_name << " --trace PATH [options]\n"
      << "\n"
      << "Options:\n"
      << "  --capacity-bytes N       Total cache data capacity (default: 8192)\n"
      << "  --line-bytes N           Cache line size (default: 32)\n"
      << "  --ways N                 Set associativity (default: 2)\n"
      << "  --hit-time-cycles N      Hit access time used by AMAT (default: 2)\n"
      << "  --refill-model MODEL     fixed, independent, or burst (default: fixed)\n"
      << "  --refill-beat-bytes N    Bytes returned by one refill beat (default: 4)\n"
      << "  --critical-response-penalty-cycles N Fixed critical-word penalty\n"
      << "  --complete-refill-penalty-cycles N Fixed complete-line penalty\n"
      << "  --dirty-writeback-penalty-cycles N Dirty victim writeback penalty\n"
      << "  --read-address-cycles N  Read-address handshake phase a (default: 1)\n"
      << "  --memory-command-cycles N Memory command phase b (default: 1)\n"
      << "  --first-data-cycles N    First data return phase c (default: 1)\n"
      << "  --response-beat-cycles N Per-beat response phase d (default: 1)\n"
      << "  --write-address-cycles N Write-address phase (default: 1)\n"
      << "  --write-data-beat-cycles N Per-beat write-data phase (default: 1)\n"
      << "  --write-response-cycles N Write-response phase (default: 1)\n"
      << "  --output-format FORMAT   text, csv, or json (default: text)\n"
      << "  --help                   Show this message\n";
}

CommandLineOptions ParseCommandLine(int argc, char **argv) {
  CommandLineOptions options;

  auto require_value = [&](int &argument_index, const char *option_name) {
    if (argument_index + 1 >= argc) {
      throw std::runtime_error(std::string("missing value after ") + option_name);
    }
    return std::string(argv[++argument_index]);
  };

  for (int argument_index = 1; argument_index < argc; ++argument_index) {
    const std::string argument = argv[argument_index];
    if (argument == "--trace") {
      options.trace_path = require_value(argument_index, "--trace");
    } else if (argument == "--capacity-bytes") {
      options.configuration.capacity_bytes = ParseUnsignedInteger(
          require_value(argument_index, "--capacity-bytes"), "--capacity-bytes");
    } else if (argument == "--line-bytes") {
      options.configuration.line_bytes = ParseUnsignedInteger(
          require_value(argument_index, "--line-bytes"), "--line-bytes");
    } else if (argument == "--ways") {
      options.configuration.way_count =
          ParseUnsignedInteger(require_value(argument_index, "--ways"), "--ways");
    } else if (argument == "--hit-time-cycles") {
      options.configuration.hit_time_cycles = ParseFloatingPoint(
          require_value(argument_index, "--hit-time-cycles"), "--hit-time-cycles");
    } else if (argument == "--refill-model") {
      options.configuration.refill_transport_model = ParseRefillTransportModel(
          require_value(argument_index, "--refill-model"));
    } else if (argument == "--refill-beat-bytes") {
      options.configuration.refill_beat_bytes = ParseUnsignedInteger(
          require_value(argument_index, "--refill-beat-bytes"),
          "--refill-beat-bytes");
    } else if (argument == "--critical-response-penalty-cycles") {
      options.configuration.critical_response_penalty_cycles = ParseFloatingPoint(
          require_value(argument_index, "--critical-response-penalty-cycles"),
          "--critical-response-penalty-cycles");
    } else if (argument == "--complete-refill-penalty-cycles") {
      options.configuration.complete_refill_penalty_cycles = ParseFloatingPoint(
          require_value(argument_index, "--complete-refill-penalty-cycles"),
          "--complete-refill-penalty-cycles");
    } else if (argument == "--dirty-writeback-penalty-cycles") {
      options.configuration.dirty_writeback_penalty_cycles = ParseFloatingPoint(
          require_value(argument_index, "--dirty-writeback-penalty-cycles"),
          "--dirty-writeback-penalty-cycles");
    } else if (argument == "--read-address-cycles") {
      options.configuration.read_address_cycles = ParseFloatingPoint(
          require_value(argument_index, "--read-address-cycles"),
          "--read-address-cycles");
    } else if (argument == "--memory-command-cycles") {
      options.configuration.memory_command_cycles = ParseFloatingPoint(
          require_value(argument_index, "--memory-command-cycles"),
          "--memory-command-cycles");
    } else if (argument == "--first-data-cycles") {
      options.configuration.first_data_cycles = ParseFloatingPoint(
          require_value(argument_index, "--first-data-cycles"),
          "--first-data-cycles");
    } else if (argument == "--response-beat-cycles") {
      options.configuration.response_beat_cycles = ParseFloatingPoint(
          require_value(argument_index, "--response-beat-cycles"),
          "--response-beat-cycles");
    } else if (argument == "--write-address-cycles") {
      options.configuration.write_address_cycles = ParseFloatingPoint(
          require_value(argument_index, "--write-address-cycles"),
          "--write-address-cycles");
    } else if (argument == "--write-data-beat-cycles") {
      options.configuration.write_data_beat_cycles = ParseFloatingPoint(
          require_value(argument_index, "--write-data-beat-cycles"),
          "--write-data-beat-cycles");
    } else if (argument == "--write-response-cycles") {
      options.configuration.write_response_cycles = ParseFloatingPoint(
          require_value(argument_index, "--write-response-cycles"),
          "--write-response-cycles");
    } else if (argument == "--output-format") {
      options.output_format = require_value(argument_index, "--output-format");
    } else if (argument == "--help") {
      PrintUsage(argv[0]);
      std::exit(0);
    } else {
      throw std::runtime_error("unknown option: " + argument);
    }
  }

  if (options.trace_path.empty()) {
    throw std::runtime_error("--trace is required");
  }
  if (options.output_format != "text" && options.output_format != "csv" &&
      options.output_format != "json") {
    throw std::runtime_error("--output-format must be text, csv, or json");
  }

  ValidateConfiguration(options.configuration);
  return options;
}

template <typename Value>
void ReadBinaryValue(std::istream &trace_stream, Value *value,
                     const char *description) {
  trace_stream.read(reinterpret_cast<char *>(value), sizeof(*value));
  if (!trace_stream) {
    throw std::runtime_error(std::string("truncated binary trace while reading ") +
                             description);
  }
}

std::optional<TraceKind> DetectBinaryTraceKind(std::istream &trace_stream) {
  char file_magic[sizeof(kBinaryTraceMagic)] = {};
  trace_stream.read(file_magic, sizeof(file_magic));
  const bool complete_magic =
      trace_stream.gcount() == static_cast<std::streamsize>(sizeof(file_magic));
  trace_stream.clear();
  trace_stream.seekg(0, std::ios::beg);
  if (!trace_stream) {
    throw std::runtime_error("failed to seek trace file");
  }
  if (!complete_magic) {
    return std::nullopt;
  }
  if (std::equal(std::begin(file_magic), std::end(file_magic),
                 std::begin(kBinaryTraceMagic))) {
    return TraceKind::kInstruction;
  }
  if (std::equal(std::begin(file_magic), std::end(file_magic),
                 std::begin(kBinaryDataTraceMagic))) {
    return TraceKind::kData;
  }
  return std::nullopt;
}

CacheStatistics SimulateTrace(std::istream &trace_stream,
                              const CacheConfiguration &configuration) {
  const uint64_t cache_line_count =
      configuration.capacity_bytes / configuration.line_bytes;
  SetAssociativeCache tested_cache(configuration);
  FullyAssociativeShadowCache fully_associative_cache(cache_line_count);
  std::unordered_set<uint64_t> previously_accessed_line_set;
  CacheStatistics statistics;

  auto access_cache_line = [&](uint64_t byte_address, bool is_write) {
    const uint64_t block_address = byte_address / configuration.line_bytes;
    const bool previously_accessed =
        previously_accessed_line_set.find(block_address) !=
        previously_accessed_line_set.end();
    const CacheAccessResult tested_cache_result =
        tested_cache.Access(block_address, is_write);
    const bool fully_associative_cache_hit =
        fully_associative_cache.Access(block_address);

    ++statistics.access_count;
    if (tested_cache_result.hit) {
      ++statistics.hit_count;
    } else {
      ++statistics.miss_count;
      statistics.critical_beat_position_sum +=
          ((byte_address % configuration.line_bytes) /
           configuration.refill_beat_bytes) +
          1;
      if (tested_cache_result.dirty_eviction_occurred) {
        ++statistics.dirty_eviction_count;
      }
      if (!previously_accessed) {
        ++statistics.compulsory_miss_count;
      } else if (fully_associative_cache_hit) {
        ++statistics.conflict_miss_count;
      } else {
        ++statistics.capacity_miss_count;
      }
    }
    previously_accessed_line_set.insert(block_address);
  };

  auto access_program_counter = [&](uint64_t program_counter) {
    ++statistics.architectural_access_count;
    access_cache_line(program_counter, false);
  };

  auto access_data = [&](uint64_t address, uint8_t transfer_byte_count,
                         bool is_write) {
    if (transfer_byte_count != 1 && transfer_byte_count != 2 &&
        transfer_byte_count != 4 && transfer_byte_count != 8) {
      throw std::runtime_error("data trace contains an invalid transfer size");
    }
    if (address > std::numeric_limits<uint64_t>::max() -
                      static_cast<uint64_t>(transfer_byte_count - 1)) {
      throw std::runtime_error("data trace access address overflow");
    }

    ++statistics.architectural_access_count;
    if (is_write) {
      ++statistics.store_access_count;
    } else {
      ++statistics.load_access_count;
    }

    const uint64_t final_address = address + transfer_byte_count - 1;
    const uint64_t first_block_address = address / configuration.line_bytes;
    const uint64_t final_block_address =
        final_address / configuration.line_bytes;
    for (uint64_t block_address = first_block_address;; ++block_address) {
      const uint64_t first_byte_in_block =
          block_address == first_block_address
              ? address
              : block_address * configuration.line_bytes;
      access_cache_line(first_byte_in_block, is_write);
      if (block_address == final_block_address) {
        break;
      }
    }
  };

  const std::optional<TraceKind> binary_trace_kind =
      DetectBinaryTraceKind(trace_stream);
  if (binary_trace_kind.has_value()) {
    BinaryTraceHeader header = {};
    ReadBinaryValue(trace_stream, &header, "header");
    statistics.trace_kind = *binary_trace_kind;
    if (header.version != kBinaryTraceVersion) {
      throw std::runtime_error("unsupported binary trace version");
    }
    if (header.address_bytes != 4 && header.address_bytes != 8) {
      throw std::runtime_error("binary trace address width must be 4 or 8");
    }

    if (*binary_trace_kind == TraceKind::kInstruction) {
      for (uint64_t run_index = 0; run_index < header.run_count; ++run_index) {
        BinaryProgramCounterRun run = {};
        ReadBinaryValue(trace_stream, &run, "program-counter run");
        ++statistics.source_line_count;
        if (run.instruction_count == 0) {
          throw std::runtime_error("binary trace contains an empty PC run");
        }

        uint64_t program_counter = run.first_program_counter;
        for (uint32_t instruction_index = 0;
             instruction_index < run.instruction_count; ++instruction_index) {
          if (header.address_bytes == 4 && program_counter > UINT32_MAX) {
            throw std::runtime_error(
                "RV32 binary trace contains a 64-bit program counter");
          }
          access_program_counter(program_counter);

          if (instruction_index + 1 == run.instruction_count) {
            continue;
          }
          const int64_t stride = run.program_counter_stride_bytes;
          if (stride >= 0) {
            if (program_counter > std::numeric_limits<uint64_t>::max() -
                                      static_cast<uint64_t>(stride)) {
              throw std::runtime_error("binary trace program counter overflow");
            }
            program_counter += static_cast<uint64_t>(stride);
          } else {
            const uint64_t magnitude = static_cast<uint64_t>(-stride);
            if (program_counter < magnitude) {
              throw std::runtime_error("binary trace program counter underflow");
            }
            program_counter -= magnitude;
          }
        }
      }
    } else {
      for (uint64_t run_index = 0; run_index < header.run_count; ++run_index) {
        BinaryDataAccessRun run = {};
        ReadBinaryValue(trace_stream, &run, "data-access run");
        ++statistics.source_line_count;
        if (run.access_count == 0) {
          throw std::runtime_error("binary trace contains an empty data run");
        }
        if ((run.flags & ~kDataAccessWrite) != 0) {
          throw std::runtime_error("data trace contains unknown access flags");
        }

        uint64_t address = run.first_address;
        for (uint32_t access_index = 0; access_index < run.access_count;
             ++access_index) {
          if (header.address_bytes == 4 && address > UINT32_MAX) {
            throw std::runtime_error(
                "RV32 binary trace contains a 64-bit data address");
          }
          access_data(address, run.transfer_byte_count,
                      (run.flags & kDataAccessWrite) != 0);

          if (access_index + 1 == run.access_count) {
            continue;
          }
          const int64_t stride = run.address_stride_bytes;
          if (stride >= 0) {
            if (address > std::numeric_limits<uint64_t>::max() -
                              static_cast<uint64_t>(stride)) {
              throw std::runtime_error("binary trace data address overflow");
            }
            address += static_cast<uint64_t>(stride);
          } else {
            const uint64_t magnitude = static_cast<uint64_t>(-stride);
            if (address < magnitude) {
              throw std::runtime_error("binary trace data address underflow");
            }
            address -= magnitude;
          }
        }
      }
    }

    if (statistics.architectural_access_count != header.access_count) {
      throw std::runtime_error("binary trace access count does not match its header");
    }
    char trailing_byte = 0;
    trace_stream.read(&trailing_byte, 1);
    if (trace_stream.gcount() != 0) {
      throw std::runtime_error("binary trace contains trailing data");
    }
  } else {
    statistics.trace_kind = TraceKind::kInstruction;
    std::string trace_line;
    while (std::getline(trace_stream, trace_line)) {
      ++statistics.source_line_count;
      const std::optional<uint64_t> program_counter =
          ParseProgramCounter(trace_line);
      if (!program_counter.has_value()) {
        if (!TrimLeft(trace_line).empty()) {
          ++statistics.ignored_nonempty_line_count;
        }
        continue;
      }
      access_program_counter(*program_counter);
    }
  }

  statistics.unique_line_count = previously_accessed_line_set.size();
  if (statistics.access_count == 0) {
    throw std::runtime_error("trace contains no recognizable cache accesses");
  }
  if (statistics.hit_count + statistics.miss_count != statistics.access_count ||
      statistics.compulsory_miss_count + statistics.capacity_miss_count +
              statistics.conflict_miss_count !=
          statistics.miss_count) {
    throw std::runtime_error("internal cache statistics conservation check failed");
  }
  if (statistics.trace_kind == TraceKind::kData &&
      statistics.load_access_count + statistics.store_access_count !=
          statistics.architectural_access_count) {
    throw std::runtime_error("data trace load/store conservation check failed");
  }
  return statistics;
}

double HitRate(const CacheStatistics &statistics) {
  return static_cast<double>(statistics.hit_count) /
         static_cast<double>(statistics.access_count);
}

double MissRate(const CacheStatistics &statistics) {
  return static_cast<double>(statistics.miss_count) /
         static_cast<double>(statistics.access_count);
}

RefillStatistics CalculateRefillStatistics(
    const CacheConfiguration &configuration,
    const CacheStatistics &cache_statistics) {
  RefillStatistics refill_statistics;
  refill_statistics.refill_beat_count_per_line =
      configuration.line_bytes / configuration.refill_beat_bytes;
  refill_statistics.transferred_beat_count =
      cache_statistics.miss_count * refill_statistics.refill_beat_count_per_line;

  if (cache_statistics.miss_count == 0) {
    return refill_statistics;
  }

  refill_statistics.average_critical_beat_position =
      static_cast<double>(cache_statistics.critical_beat_position_sum) /
      static_cast<double>(cache_statistics.miss_count);

  const double request_setup_cycles =
      configuration.read_address_cycles + configuration.memory_command_cycles;
  const double independent_transaction_cycles =
      request_setup_cycles + configuration.first_data_cycles +
      configuration.response_beat_cycles;

  switch (configuration.refill_transport_model) {
    case RefillTransportModel::kFixedPenalty:
      refill_statistics.read_transaction_count = cache_statistics.miss_count;
      refill_statistics.average_critical_response_penalty_cycles =
          configuration.critical_response_penalty_cycles;
      refill_statistics.average_complete_refill_penalty_cycles =
          configuration.complete_refill_penalty_cycles;
      refill_statistics.average_dirty_writeback_penalty_cycles =
          configuration.dirty_writeback_penalty_cycles;
      break;

    case RefillTransportModel::kIndependentReadTransactions:
      refill_statistics.read_transaction_count =
          refill_statistics.transferred_beat_count;
      refill_statistics.average_critical_response_penalty_cycles =
          refill_statistics.average_critical_beat_position *
          independent_transaction_cycles;
      refill_statistics.average_complete_refill_penalty_cycles =
          static_cast<double>(refill_statistics.refill_beat_count_per_line) *
          independent_transaction_cycles;
      refill_statistics.average_dirty_writeback_penalty_cycles =
          configuration.write_address_cycles +
          static_cast<double>(refill_statistics.refill_beat_count_per_line) *
              configuration.write_data_beat_cycles +
          configuration.write_response_cycles;
      break;

    case RefillTransportModel::kIncrementingBurst:
      refill_statistics.read_transaction_count = cache_statistics.miss_count;
      refill_statistics.average_critical_response_penalty_cycles =
          request_setup_cycles + configuration.first_data_cycles +
          refill_statistics.average_critical_beat_position *
              configuration.response_beat_cycles;
      refill_statistics.average_complete_refill_penalty_cycles =
          request_setup_cycles + configuration.first_data_cycles +
          static_cast<double>(refill_statistics.refill_beat_count_per_line) *
              configuration.response_beat_cycles;
      refill_statistics.average_dirty_writeback_penalty_cycles =
          configuration.write_address_cycles +
          static_cast<double>(refill_statistics.refill_beat_count_per_line) *
              configuration.write_data_beat_cycles +
          configuration.write_response_cycles;
      break;
  }

  refill_statistics.total_critical_miss_time_cycles =
      static_cast<double>(cache_statistics.miss_count) *
      refill_statistics.average_critical_response_penalty_cycles;
  refill_statistics.total_refill_occupancy_cycles =
      static_cast<double>(cache_statistics.miss_count) *
      refill_statistics.average_complete_refill_penalty_cycles;
  refill_statistics.total_dirty_writeback_cycles =
      static_cast<double>(cache_statistics.dirty_eviction_count) *
      refill_statistics.average_dirty_writeback_penalty_cycles;
  return refill_statistics;
}

double CriticalMissTime(const RefillStatistics &refill_statistics) {
  return refill_statistics.total_critical_miss_time_cycles +
         refill_statistics.total_dirty_writeback_cycles;
}

double BlockingMissTime(const RefillStatistics &refill_statistics) {
  return refill_statistics.total_refill_occupancy_cycles +
         refill_statistics.total_dirty_writeback_cycles;
}

double AverageMemoryAccessTime(const CacheConfiguration &configuration,
                               const CacheStatistics &statistics,
                               const RefillStatistics &refill_statistics) {
  return configuration.hit_time_cycles +
         CriticalMissTime(refill_statistics) /
             static_cast<double>(statistics.access_count);
}

double BlockingAverageMemoryAccessTime(
    const CacheConfiguration &configuration,
    const CacheStatistics &statistics,
    const RefillStatistics &refill_statistics) {
  return configuration.hit_time_cycles +
         BlockingMissTime(refill_statistics) /
             static_cast<double>(statistics.access_count);
}

void PrintText(const CacheConfiguration &configuration,
               const CacheStatistics &statistics,
               const RefillStatistics &refill_statistics) {
  const uint64_t set_count = configuration.capacity_bytes /
                             (configuration.line_bytes * configuration.way_count);
  std::cout << std::fixed << std::setprecision(6);
  std::cout << (statistics.trace_kind == TraceKind::kInstruction ? "I-cache"
                                                                  : "D-cache")
            << " metadata simulation\n";
  std::cout << "  trace kind              : "
            << TraceKindName(statistics.trace_kind) << '\n';
  std::cout << "  capacity bytes          : " << configuration.capacity_bytes << '\n';
  std::cout << "  line bytes              : " << configuration.line_bytes << '\n';
  std::cout << "  ways                    : " << configuration.way_count << '\n';
  std::cout << "  sets                    : " << set_count << '\n';
  std::cout << "  accesses                : " << statistics.access_count << '\n';
  std::cout << "  architectural accesses  : "
            << statistics.architectural_access_count << '\n';
  if (statistics.trace_kind == TraceKind::kData) {
    std::cout << "  loads / stores          : " << statistics.load_access_count
              << " / " << statistics.store_access_count << '\n';
    std::cout << "  dirty evictions         : "
              << statistics.dirty_eviction_count << '\n';
  }
  std::cout << "  hits                    : " << statistics.hit_count << '\n';
  std::cout << "  misses                  : " << statistics.miss_count << '\n';
  std::cout << "  compulsory misses       : "
            << statistics.compulsory_miss_count << '\n';
  std::cout << "  capacity misses         : " << statistics.capacity_miss_count << '\n';
  std::cout << "  conflict misses         : " << statistics.conflict_miss_count << '\n';
  std::cout << "  unique cache lines      : " << statistics.unique_line_count << '\n';
  std::cout << "  hit rate                : " << HitRate(statistics) * 100.0 << "%\n";
  std::cout << "  miss rate               : " << MissRate(statistics) * 100.0 << "%\n";
  std::cout << "  refill model            : "
            << RefillTransportModelName(configuration.refill_transport_model) << '\n';
  std::cout << "  refill beat bytes       : " << configuration.refill_beat_bytes << '\n';
  std::cout << "  refill beats per line   : "
            << refill_statistics.refill_beat_count_per_line << '\n';
  std::cout << "  average critical beat   : "
            << refill_statistics.average_critical_beat_position << '\n';
  std::cout << "  average critical penalty: "
            << refill_statistics.average_critical_response_penalty_cycles
            << " cycles\n";
  std::cout << "  average complete refill : "
            << refill_statistics.average_complete_refill_penalty_cycles
            << " cycles\n";
  std::cout << "  average dirty writeback : "
            << refill_statistics.average_dirty_writeback_penalty_cycles
            << " cycles\n";
  std::cout << "  estimated AMAT cycles   : "
            << AverageMemoryAccessTime(configuration, statistics,
                                       refill_statistics)
            << '\n';
  std::cout << "  blocking AMAT cycles    : "
            << BlockingAverageMemoryAccessTime(configuration, statistics,
                                               refill_statistics)
            << '\n';
  std::cout << "  critical-word TMT cycles: "
            << CriticalMissTime(refill_statistics) << '\n';
  std::cout << "  blocking TMT cycles     : "
            << BlockingMissTime(refill_statistics) << '\n';
  std::cout << "  refill occupancy cycles : "
            << refill_statistics.total_refill_occupancy_cycles << '\n';
  std::cout << "  dirty writeback cycles  : "
            << refill_statistics.total_dirty_writeback_cycles << '\n';
  std::cout << "  AXI read transactions   : "
            << refill_statistics.read_transaction_count << '\n';
  std::cout << "  transferred refill beats: "
            << refill_statistics.transferred_beat_count << '\n';
  std::cout << "  refill traffic bytes    : "
            << statistics.miss_count * configuration.line_bytes << '\n';
  std::cout << "  writeback traffic bytes : "
            << statistics.dirty_eviction_count * configuration.line_bytes << '\n';
  std::cout << "  ignored nonempty lines  : "
            << statistics.ignored_nonempty_line_count << '\n';
}

void PrintCsv(const CacheConfiguration &configuration,
              const CacheStatistics &statistics,
              const RefillStatistics &refill_statistics) {
  const uint64_t set_count = configuration.capacity_bytes /
                             (configuration.line_bytes * configuration.way_count);
  std::cout
      << "trace_kind,capacity_bytes,line_bytes,ways,sets,"
         "architectural_accesses,loads,stores,accesses,hits,misses,"
         "compulsory_misses,capacity_misses,conflict_misses,unique_lines,"
         "dirty_evictions,"
         "hit_rate,miss_rate,hit_time_cycles,refill_model,refill_beat_bytes,"
         "refill_beats_per_line,average_critical_beat_position,"
         "read_address_cycles,memory_command_cycles,first_data_cycles,"
         "response_beat_cycles,write_address_cycles,write_data_beat_cycles,"
         "write_response_cycles,fixed_critical_response_penalty_cycles,"
         "fixed_complete_refill_penalty_cycles,"
         "dirty_writeback_penalty_cycles,"
         "average_critical_response_penalty_cycles,"
         "average_complete_refill_penalty_cycles,"
         "average_dirty_writeback_penalty_cycles,amat_cycles,"
         "blocking_amat_cycles,critical_tmt_cycles,blocking_tmt_cycles,"
         "refill_occupancy_cycles,dirty_writeback_cycles,read_transactions,"
         "transferred_refill_beats,refill_traffic_bytes,writeback_traffic_bytes\n";
  std::cout << std::fixed << std::setprecision(9)
            << TraceKindName(statistics.trace_kind) << ','
            << configuration.capacity_bytes << ',' << configuration.line_bytes << ','
            << configuration.way_count << ',' << set_count << ','
            << statistics.architectural_access_count << ','
            << statistics.load_access_count << ','
            << statistics.store_access_count << ','
            << statistics.access_count << ',' << statistics.hit_count << ','
            << statistics.miss_count << ','
            << statistics.compulsory_miss_count << ','
            << statistics.capacity_miss_count << ','
            << statistics.conflict_miss_count << ','
            << statistics.unique_line_count << ','
            << statistics.dirty_eviction_count << ',' << HitRate(statistics) << ','
            << MissRate(statistics) << ',' << configuration.hit_time_cycles << ','
            << RefillTransportModelName(configuration.refill_transport_model) << ','
            << configuration.refill_beat_bytes << ','
            << refill_statistics.refill_beat_count_per_line << ','
            << refill_statistics.average_critical_beat_position << ','
            << configuration.read_address_cycles << ','
            << configuration.memory_command_cycles << ','
            << configuration.first_data_cycles << ','
            << configuration.response_beat_cycles << ','
            << configuration.write_address_cycles << ','
            << configuration.write_data_beat_cycles << ','
            << configuration.write_response_cycles << ','
            << configuration.critical_response_penalty_cycles << ','
            << configuration.complete_refill_penalty_cycles << ','
            << configuration.dirty_writeback_penalty_cycles << ','
            << refill_statistics.average_critical_response_penalty_cycles << ','
            << refill_statistics.average_complete_refill_penalty_cycles << ','
            << refill_statistics.average_dirty_writeback_penalty_cycles << ','
            << AverageMemoryAccessTime(configuration, statistics,
                                       refill_statistics)
            << ','
            << BlockingAverageMemoryAccessTime(configuration, statistics,
                                               refill_statistics)
            << ',' << CriticalMissTime(refill_statistics) << ','
            << BlockingMissTime(refill_statistics) << ','
            << refill_statistics.total_refill_occupancy_cycles << ','
            << refill_statistics.total_dirty_writeback_cycles << ','
            << refill_statistics.read_transaction_count << ','
            << refill_statistics.transferred_beat_count << ','
            << statistics.miss_count * configuration.line_bytes << ','
            << statistics.dirty_eviction_count * configuration.line_bytes << '\n';
}

void PrintJson(const CacheConfiguration &configuration,
               const CacheStatistics &statistics,
               const RefillStatistics &refill_statistics) {
  const uint64_t set_count = configuration.capacity_bytes /
                             (configuration.line_bytes * configuration.way_count);
  std::cout << std::fixed << std::setprecision(9);
  std::cout << "{\n"
            << "  \"trace_kind\": \"" << TraceKindName(statistics.trace_kind)
            << "\",\n"
            << "  \"capacity_bytes\": " << configuration.capacity_bytes << ",\n"
            << "  \"line_bytes\": " << configuration.line_bytes << ",\n"
            << "  \"ways\": " << configuration.way_count << ",\n"
            << "  \"sets\": " << set_count << ",\n"
            << "  \"architectural_accesses\": "
            << statistics.architectural_access_count << ",\n"
            << "  \"loads\": " << statistics.load_access_count << ",\n"
            << "  \"stores\": " << statistics.store_access_count << ",\n"
            << "  \"accesses\": " << statistics.access_count << ",\n"
            << "  \"hits\": " << statistics.hit_count << ",\n"
            << "  \"misses\": " << statistics.miss_count << ",\n"
            << "  \"compulsory_misses\": "
            << statistics.compulsory_miss_count << ",\n"
            << "  \"capacity_misses\": " << statistics.capacity_miss_count << ",\n"
            << "  \"conflict_misses\": " << statistics.conflict_miss_count << ",\n"
            << "  \"unique_lines\": " << statistics.unique_line_count << ",\n"
            << "  \"dirty_evictions\": " << statistics.dirty_eviction_count
            << ",\n"
            << "  \"hit_rate\": " << HitRate(statistics) << ",\n"
            << "  \"miss_rate\": " << MissRate(statistics) << ",\n"
            << "  \"hit_time_cycles\": " << configuration.hit_time_cycles << ",\n"
            << "  \"refill_model\": \""
            << RefillTransportModelName(configuration.refill_transport_model)
            << "\",\n"
            << "  \"refill_beat_bytes\": " << configuration.refill_beat_bytes
            << ",\n"
            << "  \"refill_beats_per_line\": "
            << refill_statistics.refill_beat_count_per_line << ",\n"
            << "  \"average_critical_beat_position\": "
            << refill_statistics.average_critical_beat_position << ",\n"
            << "  \"read_address_cycles\": "
            << configuration.read_address_cycles << ",\n"
            << "  \"memory_command_cycles\": "
            << configuration.memory_command_cycles << ",\n"
            << "  \"first_data_cycles\": " << configuration.first_data_cycles
            << ",\n"
            << "  \"response_beat_cycles\": "
            << configuration.response_beat_cycles << ",\n"
            << "  \"write_address_cycles\": "
            << configuration.write_address_cycles << ",\n"
            << "  \"write_data_beat_cycles\": "
            << configuration.write_data_beat_cycles << ",\n"
            << "  \"write_response_cycles\": "
            << configuration.write_response_cycles << ",\n"
            << "  \"fixed_critical_response_penalty_cycles\": "
            << configuration.critical_response_penalty_cycles << ",\n"
            << "  \"fixed_complete_refill_penalty_cycles\": "
            << configuration.complete_refill_penalty_cycles << ",\n"
            << "  \"dirty_writeback_penalty_cycles\": "
            << configuration.dirty_writeback_penalty_cycles << ",\n"
            << "  \"average_critical_response_penalty_cycles\": "
            << refill_statistics.average_critical_response_penalty_cycles
            << ",\n"
            << "  \"average_complete_refill_penalty_cycles\": "
            << refill_statistics.average_complete_refill_penalty_cycles
            << ",\n"
            << "  \"average_dirty_writeback_penalty_cycles\": "
            << refill_statistics.average_dirty_writeback_penalty_cycles
            << ",\n"
            << "  \"amat_cycles\": "
            << AverageMemoryAccessTime(configuration, statistics,
                                       refill_statistics)
            << ",\n"
            << "  \"blocking_amat_cycles\": "
            << BlockingAverageMemoryAccessTime(configuration, statistics,
                                               refill_statistics)
            << ",\n"
            << "  \"critical_tmt_cycles\": "
            << CriticalMissTime(refill_statistics) << ",\n"
            << "  \"blocking_tmt_cycles\": "
            << BlockingMissTime(refill_statistics) << ",\n"
            << "  \"refill_occupancy_cycles\": "
            << refill_statistics.total_refill_occupancy_cycles << ",\n"
            << "  \"dirty_writeback_cycles\": "
            << refill_statistics.total_dirty_writeback_cycles << ",\n"
            << "  \"read_transactions\": "
            << refill_statistics.read_transaction_count << ",\n"
            << "  \"transferred_refill_beats\": "
            << refill_statistics.transferred_beat_count << ",\n"
            << "  \"refill_traffic_bytes\": "
            << statistics.miss_count * configuration.line_bytes << ",\n"
            << "  \"writeback_traffic_bytes\": "
            << statistics.dirty_eviction_count * configuration.line_bytes
            << ",\n"
            << "  \"source_lines\": " << statistics.source_line_count << ",\n"
            << "  \"ignored_nonempty_lines\": "
            << statistics.ignored_nonempty_line_count << "\n"
            << "}\n";
}

}  // namespace

int main(int argc, char **argv) {
  try {
    const CommandLineOptions options = ParseCommandLine(argc, argv);
    std::ifstream trace_file(options.trace_path, std::ios::binary);
    if (!trace_file) {
      throw std::runtime_error("cannot open trace file: " + options.trace_path);
    }

    const CacheStatistics statistics =
        SimulateTrace(trace_file, options.configuration);
    const RefillStatistics refill_statistics =
        CalculateRefillStatistics(options.configuration, statistics);
    if (options.output_format == "text") {
      PrintText(options.configuration, statistics, refill_statistics);
    } else if (options.output_format == "csv") {
      PrintCsv(options.configuration, statistics, refill_statistics);
    } else {
      PrintJson(options.configuration, statistics, refill_statistics);
    }
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "cachesim: " << error.what() << '\n';
    return 1;
  }
}
