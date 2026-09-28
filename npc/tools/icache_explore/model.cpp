// Functional instruction-cache screening. OPT is the only future-aware policy.
// No CPU timing, speculative path, in-flight refill or area claims are made here.
#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

struct Run { uint64_t line; uint64_t count; uint64_t next; };
struct Entry {
  uint64_t line = 0, born = 0, next = 0;
  int64_t last = 0;
  unsigned rrpv = 3, signature = 0;
  bool present = false, reused = false;
};
struct Config { unsigned bytes, ways, line_bytes; std::string policy; };
struct Result { uint64_t misses = 0, table_reads = 0, table_writes = 0; };

static uint64_t little(const unsigned char *p, unsigned bytes) {
  uint64_t value = 0;
  for (unsigned i = 0; i < bytes; ++i) value |= uint64_t(p[i]) << (i * 8);
  return value;
}

static std::vector<uint64_t> read_trace(const std::string &path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("cannot read trace");
  std::array<unsigned char, 32> header{};
  input.read(reinterpret_cast<char *>(header.data()), header.size());
  std::vector<uint64_t> pcs;
  if (std::string(reinterpret_cast<char *>(header.data()), 8) == "NPCPCTR1") {
    if (little(header.data() + 8, 4) != 1) throw std::runtime_error("bad trace version");
    uint64_t count = little(header.data() + 16, 8), run_count = little(header.data() + 24, 8);
    pcs.reserve(count);
    for (uint64_t i = 0; i < run_count; ++i) {
      std::array<unsigned char, 16> run{};
      if (!input.read(reinterpret_cast<char *>(run.data()), run.size())) throw std::runtime_error("truncated trace");
      uint64_t pc = little(run.data(), 8);
      uint32_t length = little(run.data() + 8, 4);
      int32_t stride = static_cast<int32_t>(little(run.data() + 12, 4));
      for (uint32_t j = 0; j < length; ++j) pcs.push_back(pc + int64_t(j) * stride);
    }
    if (pcs.size() != count || input.peek() != EOF) throw std::runtime_error("trace length mismatch");
  } else {
    input.clear(); input.seekg(0);
    std::string row;
    while (std::getline(input, row)) if (!row.empty()) pcs.push_back(std::stoull(row.substr(0, row.find(',')), nullptr, 16));
  }
  if (pcs.empty()) throw std::runtime_error("empty trace");
  return pcs;
}

static std::vector<Run> compress(const std::vector<uint64_t> &pcs, unsigned line_bytes) {
  std::vector<Run> runs;
  for (auto pc : pcs) {
    uint64_t line = pc / line_bytes;
    if (!runs.empty() && runs.back().line == line) ++runs.back().count;
    else runs.push_back({line, 1, 0});
  }
  std::unordered_map<uint64_t, uint64_t> next;
  for (size_t i = runs.size(); i-- > 0;) {
    auto found = next.find(runs[i].line);
    runs[i].next = found == next.end() ? runs.size() : found->second;
    next[runs[i].line] = i;
  }
  return runs;
}

static Result simulate(const std::vector<Run> &runs, const Config &config, std::ostream *events = nullptr) {
  auto power_of_two = [](unsigned n) { return n && !(n & (n - 1)); };
  if (!power_of_two(config.bytes) || !power_of_two(config.ways) || !power_of_two(config.line_bytes)
      || config.bytes < config.ways * config.line_bytes) throw std::runtime_error("bad geometry");
  const std::string &policy = config.policy;
  const std::vector<std::string> names = {"fifo", "lru", "plru", "random", "lip", "bip", "srrip", "insert3", "brrip", "drrip", "burst_rrip", "burst_pc", "burst_history", "opt"};
  if (std::find(names.begin(), names.end(), policy) == names.end()) throw std::runtime_error("unknown policy");
  unsigned set_count = config.bytes / config.ways / config.line_bytes;
  std::vector<std::vector<Entry>> sets(set_count, std::vector<Entry>(config.ways));
  std::vector<unsigned> fifo(set_count), tree(set_count);
  std::array<unsigned, 64> prediction{}; prediction.fill(1);
  unsigned selector = 511, history = 0;
  uint32_t random = 97531;
  bool burst = policy == "burst_rrip" || policy == "burst_pc" || policy == "burst_history";
  bool learned = policy == "burst_pc" || policy == "burst_history";
  bool rrip = policy == "srrip" || policy == "insert3" || policy == "brrip" || policy == "drrip" || burst;
  Result result;
  for (uint64_t step = 0; step < runs.size(); ++step) {
    const Run &run = runs[step];
    unsigned set_index = run.line & (set_count - 1);
    auto &entries = sets[set_index];
    unsigned way = config.ways;
    for (unsigned i = 0; i < config.ways; ++i) if (entries[i].present && entries[i].line == run.line) { way = i; break; }
    bool missed = way == config.ways;
    unsigned signature = (run.line ^ (run.line >> 6) ^ (policy == "burst_history" ? history : 0)) & 63;
    if (missed) {
      ++result.misses;
      for (unsigned i = 0; i < config.ways; ++i) if (!entries[i].present) { way = i; break; }
      if (way == config.ways) {
        way = 0;
        if (rrip) {
          unsigned maximum = 0;
          for (const auto &entry : entries) maximum = std::max(maximum, entry.rrpv);
          for (auto &entry : entries) entry.rrpv += 3 - maximum;
          while (entries[way].rrpv != 3) ++way;
        } else if (policy == "fifo") way = fifo[set_index];
        else if (policy == "random") way = random & (config.ways - 1);
        else if (policy == "plru") {
          unsigned node = 0;
          for (unsigned span = config.ways; span > 1; span >>= 1) {
            unsigned direction = (tree[set_index] >> node) & 1;
            way = (way << 1) | direction; node = 2 * node + 1 + direction;
          }
        } else if (policy == "opt") {
          for (unsigned i = 1; i < config.ways; ++i) if (entries[i].next > entries[way].next) way = i;
        } else {
          for (unsigned i = 1; i < config.ways; ++i) if (entries[i].last < entries[way].last) way = i;
        }
      }
      if (learned && entries[way].present && !entries[way].reused) {
        unsigned &counter = prediction[entries[way].signature];
        if (counter) --counter;
        ++result.table_writes;
      }
      bool bimodal = policy == "brrip";
      if (policy == "drrip") {
        unsigned stride = std::min(32u, std::max(4u, set_count));
        unsigned leader = set_index % stride;
        if (leader == 0) { selector = std::min(1023u, selector + 1); bimodal = false; }
        else if (leader == stride - 1) { if (selector) --selector; bimodal = true; }
        else bimodal = selector >= 512;
      }
      unsigned insertion = policy == "insert3" || (bimodal && result.misses % 32) ? 3 : 2;
      if (learned) { insertion = prediction[signature] ? 2 : 3; ++result.table_reads; }
      int64_t stamp = static_cast<int64_t>(step + 1);
      if (policy == "lip" || (policy == "bip" && result.misses % 32)) {
        for (const auto &entry : entries) if (entry.present) stamp = std::min(stamp, entry.last - 1);
      }
      entries[way] = {run.line, step, run.next, stamp, insertion, signature, true, false};
      fifo[set_index] = (way + 1) & (config.ways - 1);
      random ^= random << 13; random ^= random >> 17; random ^= random << 5;
    } else {
      entries[way].last = step + 1;
      entries[way].next = run.next;
      if (rrip) entries[way].rrpv = 0;
      if (learned && !entries[way].reused) {
        unsigned &counter = prediction[entries[way].signature];
        counter = std::min(3u, counter + 1); entries[way].reused = true;
        ++result.table_writes;
      }
    }
    // Compress only storage/iteration. Conventional policies still observe hits
    // within this run; burst-qualified policies deliberately suppress them.
    if (run.count > 1) {
      if (rrip && !burst) entries[way].rrpv = 0;
      entries[way].last = step + 1;
    }
    if (events) {
      for (uint64_t access = 0; access < run.count; ++access)
        *events << std::hex << run.line * config.line_bytes << ' ' << std::dec
                << (missed && access == 0) << ' ' << way << '\n';
    }
    unsigned node = 0;
    for (unsigned span = config.ways; span > 1; span >>= 1) {
      unsigned direction = (way & (span >> 1)) ? 1 : 0;
      tree[set_index] = (tree[set_index] & ~(1u << node)) | ((direction ^ 1u) << node);
      node = 2 * node + 1 + direction;
    }
    history = ((history << 3) ^ (run.line & 7)) & 0xffff;
  }
  return result;
}

int main(int argc, char **argv) {
  try {
    if (argc != 4 && argc != 5) throw std::runtime_error("usage: model TRACE CONFIG.csv OUTPUT.csv [EVENTS]");
    auto pcs = read_trace(argv[1]);
    std::ifstream configs(argv[2]); std::ofstream output(argv[3]);
    if (!configs || !output) throw std::runtime_error("file open failed");
    output << "bytes,ways,line_bytes,policy,accesses,misses,unique_lines,refill_bytes,table_reads,table_writes\n";
    std::ofstream events;
    if (argc == 5) { events.open(argv[4]); if (!events) throw std::runtime_error("event file open failed"); }
    std::map<unsigned, std::vector<Run>> traces;
    std::string row;
    while (std::getline(configs, row)) {
      std::replace(row.begin(), row.end(), ',', ' '); std::istringstream fields(row);
      Config c{}; if (!(fields >> c.bytes >> c.ways >> c.line_bytes >> c.policy)) throw std::runtime_error("bad config row");
      if (!traces.count(c.line_bytes)) traces.emplace(c.line_bytes, compress(pcs, c.line_bytes));
      const auto &runs = traces.at(c.line_bytes);
      auto result = simulate(runs, c, argc == 5 ? &events : nullptr); std::unordered_set<uint64_t> unique;
      for (const auto &run : runs) unique.insert(run.line);
      output << c.bytes << ',' << c.ways << ',' << c.line_bytes << ',' << c.policy << ',' << pcs.size() << ','
             << result.misses << ',' << unique.size() << ',' << result.misses * c.line_bytes << ','
             << result.table_reads << ',' << result.table_writes << '\n';
    }
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
