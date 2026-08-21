#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
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

struct CacheConfiguration {
  uint64_t capacity_bytes = 8192;
  uint64_t line_bytes = 32;
  uint64_t way_count = 2;
  uint64_t refill_beat_bytes = 4;
  double hit_time_cycles = 2.0;
  double miss_penalty_cycles = 0.0;
  double read_address_cycles = 1.0;
  double memory_command_cycles = 1.0;
  double first_data_cycles = 1.0;
  double response_beat_cycles = 1.0;
  RefillTransportModel refill_transport_model =
      RefillTransportModel::kFixedPenalty;
};

struct CacheStatistics {
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
};

struct RefillStatistics {
  uint64_t refill_beat_count_per_line = 0;
  uint64_t read_transaction_count = 0;
  uint64_t transferred_beat_count = 0;
  double average_critical_beat_position = 0.0;
  double average_critical_response_penalty_cycles = 0.0;
  double average_complete_refill_penalty_cycles = 0.0;
  double total_critical_miss_time_cycles = 0.0;
  double total_refill_occupancy_cycles = 0.0;
};

struct CacheLine {
  bool present = false;
  uint64_t tag = 0;
  uint64_t last_access_sequence = 0;
};

class SetAssociativeCache {
 public:
  explicit SetAssociativeCache(const CacheConfiguration &configuration)
      : way_count_(configuration.way_count),
        set_count_(configuration.capacity_bytes /
                   (configuration.line_bytes * configuration.way_count)),
        set_array_(set_count_, std::vector<CacheLine>(way_count_)) {}

  bool Access(uint64_t block_address) {
    ++access_sequence_;

    const uint64_t set_index = block_address % set_count_;
    const uint64_t tag = block_address / set_count_;
    std::vector<CacheLine> &set = set_array_[set_index];

    for (CacheLine &line : set) {
      if (line.present && line.tag == tag) {
        line.last_access_sequence = access_sequence_;
        return true;
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

    replacement_line->present = true;
    replacement_line->tag = tag;
    replacement_line->last_access_sequence = access_sequence_;
    return false;
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
  if (!std::isfinite(configuration.miss_penalty_cycles) ||
      configuration.miss_penalty_cycles < 0.0) {
    throw std::runtime_error("miss penalty must be a finite nonnegative number");
  }
  const double refill_phase_cycles[] = {
      configuration.read_address_cycles,
      configuration.memory_command_cycles,
      configuration.first_data_cycles,
      configuration.response_beat_cycles,
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
      << "  --miss-penalty-cycles N  Penalty used only by the fixed model\n"
      << "  --read-address-cycles N  Read-address handshake phase a (default: 1)\n"
      << "  --memory-command-cycles N Memory command phase b (default: 1)\n"
      << "  --first-data-cycles N    First data return phase c (default: 1)\n"
      << "  --response-beat-cycles N Per-beat response phase d (default: 1)\n"
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
    } else if (argument == "--miss-penalty-cycles") {
      options.configuration.miss_penalty_cycles = ParseFloatingPoint(
          require_value(argument_index, "--miss-penalty-cycles"),
          "--miss-penalty-cycles");
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

CacheStatistics SimulateTrace(std::istream &trace_stream,
                              const CacheConfiguration &configuration) {
  const uint64_t cache_line_count =
      configuration.capacity_bytes / configuration.line_bytes;
  SetAssociativeCache tested_cache(configuration);
  FullyAssociativeShadowCache fully_associative_cache(cache_line_count);
  std::unordered_set<uint64_t> previously_accessed_line_set;
  CacheStatistics statistics;

  std::string trace_line;
  while (std::getline(trace_stream, trace_line)) {
    ++statistics.source_line_count;
    const std::optional<uint64_t> program_counter = ParseProgramCounter(trace_line);
    if (!program_counter.has_value()) {
      if (!TrimLeft(trace_line).empty()) {
        ++statistics.ignored_nonempty_line_count;
      }
      continue;
    }

    const uint64_t block_address = *program_counter / configuration.line_bytes;
    const bool previously_accessed =
        previously_accessed_line_set.find(block_address) !=
        previously_accessed_line_set.end();
    const bool tested_cache_hit = tested_cache.Access(block_address);
    const bool fully_associative_cache_hit =
        fully_associative_cache.Access(block_address);

    ++statistics.access_count;
    if (tested_cache_hit) {
      ++statistics.hit_count;
    } else {
      ++statistics.miss_count;
      statistics.critical_beat_position_sum +=
          ((*program_counter % configuration.line_bytes) /
           configuration.refill_beat_bytes) +
          1;
      if (!previously_accessed) {
        ++statistics.compulsory_miss_count;
      } else if (fully_associative_cache_hit) {
        ++statistics.conflict_miss_count;
      } else {
        ++statistics.capacity_miss_count;
      }
    }
    previously_accessed_line_set.insert(block_address);
  }

  statistics.unique_line_count = previously_accessed_line_set.size();
  if (statistics.access_count == 0) {
    throw std::runtime_error("trace contains no recognizable program-counter records");
  }
  if (statistics.hit_count + statistics.miss_count != statistics.access_count ||
      statistics.compulsory_miss_count + statistics.capacity_miss_count +
              statistics.conflict_miss_count !=
          statistics.miss_count) {
    throw std::runtime_error("internal cache statistics conservation check failed");
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
          configuration.miss_penalty_cycles;
      refill_statistics.average_complete_refill_penalty_cycles =
          configuration.miss_penalty_cycles;
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
      break;
  }

  refill_statistics.total_critical_miss_time_cycles =
      static_cast<double>(cache_statistics.miss_count) *
      refill_statistics.average_critical_response_penalty_cycles;
  refill_statistics.total_refill_occupancy_cycles =
      static_cast<double>(cache_statistics.miss_count) *
      refill_statistics.average_complete_refill_penalty_cycles;
  return refill_statistics;
}

double AverageMemoryAccessTime(const CacheConfiguration &configuration,
                               const CacheStatistics &statistics,
                               const RefillStatistics &refill_statistics) {
  return configuration.hit_time_cycles +
         refill_statistics.total_critical_miss_time_cycles /
             static_cast<double>(statistics.access_count);
}

void PrintText(const CacheConfiguration &configuration,
               const CacheStatistics &statistics,
               const RefillStatistics &refill_statistics) {
  const uint64_t set_count = configuration.capacity_bytes /
                             (configuration.line_bytes * configuration.way_count);
  std::cout << std::fixed << std::setprecision(6);
  std::cout << "I-cache metadata simulation\n";
  std::cout << "  capacity bytes          : " << configuration.capacity_bytes << '\n';
  std::cout << "  line bytes              : " << configuration.line_bytes << '\n';
  std::cout << "  ways                    : " << configuration.way_count << '\n';
  std::cout << "  sets                    : " << set_count << '\n';
  std::cout << "  accesses                : " << statistics.access_count << '\n';
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
  std::cout << "  estimated AMAT cycles   : "
            << AverageMemoryAccessTime(configuration, statistics,
                                       refill_statistics)
            << '\n';
  std::cout << "  critical-word TMT cycles: "
            << refill_statistics.total_critical_miss_time_cycles << '\n';
  std::cout << "  refill occupancy cycles : "
            << refill_statistics.total_refill_occupancy_cycles << '\n';
  std::cout << "  AXI read transactions   : "
            << refill_statistics.read_transaction_count << '\n';
  std::cout << "  transferred refill beats: "
            << refill_statistics.transferred_beat_count << '\n';
  std::cout << "  refill traffic bytes    : "
            << statistics.miss_count * configuration.line_bytes << '\n';
  std::cout << "  ignored nonempty lines  : "
            << statistics.ignored_nonempty_line_count << '\n';
}

void PrintCsv(const CacheConfiguration &configuration,
              const CacheStatistics &statistics,
              const RefillStatistics &refill_statistics) {
  const uint64_t set_count = configuration.capacity_bytes /
                             (configuration.line_bytes * configuration.way_count);
  std::cout
      << "capacity_bytes,line_bytes,ways,sets,accesses,hits,misses,"
         "compulsory_misses,capacity_misses,conflict_misses,unique_lines,"
         "hit_rate,miss_rate,hit_time_cycles,refill_model,refill_beat_bytes,"
         "refill_beats_per_line,average_critical_beat_position,"
         "read_address_cycles,memory_command_cycles,first_data_cycles,"
         "response_beat_cycles,fixed_miss_penalty_cycles,"
         "average_critical_response_penalty_cycles,"
         "average_complete_refill_penalty_cycles,amat_cycles,"
         "critical_tmt_cycles,refill_occupancy_cycles,read_transactions,"
         "transferred_refill_beats,refill_traffic_bytes\n";
  std::cout << std::fixed << std::setprecision(9)
            << configuration.capacity_bytes << ',' << configuration.line_bytes << ','
            << configuration.way_count << ',' << set_count << ','
            << statistics.access_count << ',' << statistics.hit_count << ','
            << statistics.miss_count << ','
            << statistics.compulsory_miss_count << ','
            << statistics.capacity_miss_count << ','
            << statistics.conflict_miss_count << ','
            << statistics.unique_line_count << ',' << HitRate(statistics) << ','
            << MissRate(statistics) << ',' << configuration.hit_time_cycles << ','
            << RefillTransportModelName(configuration.refill_transport_model) << ','
            << configuration.refill_beat_bytes << ','
            << refill_statistics.refill_beat_count_per_line << ','
            << refill_statistics.average_critical_beat_position << ','
            << configuration.read_address_cycles << ','
            << configuration.memory_command_cycles << ','
            << configuration.first_data_cycles << ','
            << configuration.response_beat_cycles << ','
            << configuration.miss_penalty_cycles << ','
            << refill_statistics.average_critical_response_penalty_cycles << ','
            << refill_statistics.average_complete_refill_penalty_cycles << ','
            << AverageMemoryAccessTime(configuration, statistics,
                                       refill_statistics)
            << ',' << refill_statistics.total_critical_miss_time_cycles << ','
            << refill_statistics.total_refill_occupancy_cycles << ','
            << refill_statistics.read_transaction_count << ','
            << refill_statistics.transferred_beat_count << ','
            << statistics.miss_count * configuration.line_bytes << '\n';
}

void PrintJson(const CacheConfiguration &configuration,
               const CacheStatistics &statistics,
               const RefillStatistics &refill_statistics) {
  const uint64_t set_count = configuration.capacity_bytes /
                             (configuration.line_bytes * configuration.way_count);
  std::cout << std::fixed << std::setprecision(9);
  std::cout << "{\n"
            << "  \"capacity_bytes\": " << configuration.capacity_bytes << ",\n"
            << "  \"line_bytes\": " << configuration.line_bytes << ",\n"
            << "  \"ways\": " << configuration.way_count << ",\n"
            << "  \"sets\": " << set_count << ",\n"
            << "  \"accesses\": " << statistics.access_count << ",\n"
            << "  \"hits\": " << statistics.hit_count << ",\n"
            << "  \"misses\": " << statistics.miss_count << ",\n"
            << "  \"compulsory_misses\": "
            << statistics.compulsory_miss_count << ",\n"
            << "  \"capacity_misses\": " << statistics.capacity_miss_count << ",\n"
            << "  \"conflict_misses\": " << statistics.conflict_miss_count << ",\n"
            << "  \"unique_lines\": " << statistics.unique_line_count << ",\n"
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
            << "  \"fixed_miss_penalty_cycles\": "
            << configuration.miss_penalty_cycles << ",\n"
            << "  \"average_critical_response_penalty_cycles\": "
            << refill_statistics.average_critical_response_penalty_cycles
            << ",\n"
            << "  \"average_complete_refill_penalty_cycles\": "
            << refill_statistics.average_complete_refill_penalty_cycles
            << ",\n"
            << "  \"amat_cycles\": "
            << AverageMemoryAccessTime(configuration, statistics,
                                       refill_statistics)
            << ",\n"
            << "  \"critical_tmt_cycles\": "
            << refill_statistics.total_critical_miss_time_cycles << ",\n"
            << "  \"refill_occupancy_cycles\": "
            << refill_statistics.total_refill_occupancy_cycles << ",\n"
            << "  \"read_transactions\": "
            << refill_statistics.read_transaction_count << ",\n"
            << "  \"transferred_refill_beats\": "
            << refill_statistics.transferred_beat_count << ",\n"
            << "  \"refill_traffic_bytes\": "
            << statistics.miss_count * configuration.line_bytes << ",\n"
            << "  \"source_lines\": " << statistics.source_line_count << ",\n"
            << "  \"ignored_nonempty_lines\": "
            << statistics.ignored_nonempty_line_count << "\n"
            << "}\n";
}

}  // namespace

int main(int argc, char **argv) {
  try {
    const CommandLineOptions options = ParseCommandLine(argc, argv);
    std::ifstream trace_file(options.trace_path);
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
