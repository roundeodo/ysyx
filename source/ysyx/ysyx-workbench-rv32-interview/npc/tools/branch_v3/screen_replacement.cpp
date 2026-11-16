#include "replacement_btb.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

// Q/F/C use baseline identities and timing. Cache writes are applied after all
// queries/resolutions on their edge, before any query on the following edge.
struct Event {
  uint32_t operation, id, cycle, pc, target, kind, taken, roi;
  uint32_t observed_hit, observed_target, observed_kind, directions;
  uint32_t keep_snapshot, call_hints;
};
static_assert(sizeof(Event) == 56);

struct Counts {
  uint64_t branches = 0, conditional = 0, direction_errors = 0, next_pc_errors = 0;
  uint64_t taken = 0, target_absent = 0, target_wrong = 0;
  uint64_t hint_attempts = 0, hint_dropped = 0, confidence_rejected = 0;
  unsigned query_snapshots_max = 0, retirement_snapshots_max = 0;
};

struct Hint { uint32_t pc, target; unsigned kind; };
struct QueryContext {
  uint32_t id, predicted_pc, predicted_target;
  bool predicted_taken, raw_direction;
  ReplacementHit hit;
};
struct RetirementContext { uint32_t id; ReplacementHit hit; bool eligible; };

struct Experiment {
  unsigned id, prefill, direction;
  ReplacementBtb table;
  Counts counts;
  std::vector<QueryContext> queries;
  std::vector<RetirementContext> retirements;
  std::array<Hint, 4> hints;
  unsigned hint_head = 0, hint_count = 0;
  bool commit_present = false;
  RetirementContext commit{};

  Experiment(unsigned identifier, ReplacementConfig config, unsigned mode, unsigned dir) :
      id(identifier), prefill(mode), direction(dir), table(config) {
    queries.reserve(16);
    retirements.reserve(16);
  }
  void query(const Event &event, const std::vector<uint32_t> &ras) {
    auto hit = table.lookup(event.pc);
    if (id == 0 && (hit.present != bool(event.observed_hit) ||
                   (hit.present && (hit.target != event.observed_target || hit.kind != event.observed_kind))))
      throw std::runtime_error("Legacy baseline BTB lookup differs from actual RTL");
    if (!event.keep_snapshot) return;  // Evaluator storage only; lookup above remains unconditional.
    bool raw = (event.directions >> direction) & 1;
    bool taken = hit.present && (hit.kind != 0 || raw);
    uint32_t target = hit.target;
    if (hit.present && hit.kind == 3 && !ras.empty()) target = ras.back();
    queries.push_back({event.id, taken ? target : event.pc + 4, target, taken, raw, hit});
    counts.query_snapshots_max = std::max<unsigned>(counts.query_snapshots_max, queries.size());
    if (queries.size() > 16) throw std::runtime_error("Query context budget exceeded");
  }
  void resolve(const Event &event) {
    auto found = std::find_if(queries.begin(), queries.end(), [&](const auto &q) { return q.id == event.id; });
    if (found == queries.end()) throw std::runtime_error("Resolution identity not present");
    QueryContext saved = *found;
    *found = queries.back(); queries.pop_back();
    if (event.roi) {
      ++counts.branches;
      counts.next_pc_errors += saved.predicted_pc != (event.taken ? event.target : event.pc + 4);
      if (event.kind == 0) {
        ++counts.conditional;
        counts.direction_errors += saved.raw_direction != bool(event.taken);
      }
      if (event.taken) {
        ++counts.taken;
        counts.target_absent += !saved.hit.present;
        counts.target_wrong += saved.hit.present && saved.predicted_target != event.target;
      }
    }
    auto installed = table.train(event.pc, event.target, event.kind, event.taken);
    bool useful = saved.hit.present && saved.predicted_taken && event.taken && saved.predicted_target == event.target;
    auto token = saved.hit;
    if (table.policy() == Replacement::RetireTaken) {
      token = installed;
      useful = event.taken;
    }
    retirements.push_back({event.id, token, useful});
    counts.retirement_snapshots_max = std::max<unsigned>(counts.retirement_snapshots_max, retirements.size());
    if (retirements.size() > 16) throw std::runtime_error("Retirement context budget exceeded");
  }
  void retire(uint32_t id) {
    auto found = std::find_if(retirements.begin(), retirements.end(), [&](const auto &r) { return r.id == id; });
    if (found == retirements.end()) throw std::runtime_error("Retirement identity not present");
    if (commit_present) throw std::runtime_error("More than one retirement at an edge");
    commit = *found;
    commit_present = true;
    *found = retirements.back(); retirements.pop_back();
  }
  void squash(uint32_t cutoff) {
    queries.erase(std::remove_if(queries.begin(), queries.end(), [&](const auto &q) {return q.id > cutoff;}), queries.end());
    retirements.erase(std::remove_if(retirements.begin(), retirements.end(), [&](const auto &r) {return r.id > cutoff;}), retirements.end());
    // A core redirect cancels instruction snapshots, not already validated line hints.
  }
  void hint_enqueue(Hint value, int32_t displacement) {
    if (!prefill || (prefill == 2 && value.kind == 0 && displacement >= 0)) return;
    if (hint_count == 4) { ++counts.hint_dropped; return; }
    hints[(hint_head + hint_count) & 3] = value;
    ++hint_count;
  }
  void hint_tick(const std::array<unsigned, 16> &bht) {
    if (!hint_count) return;
    auto hint = hints[hint_head];
    hint_head = (hint_head + 1) & 3;
    --hint_count;
    if (prefill == 3 && hint.kind == 0 && bht[(hint.pc >> 2) & 15] != 3) {
      ++counts.confidence_rejected;
      return;
    }
    ++counts.hint_attempts;
    table.train(hint.pc, hint.target, hint.kind, true, true, prefill == 4);
  }
  void finish_edge(bool resolution_busy, const std::array<unsigned, 16> &bht) {
    bool feedback_write = false;
    if (commit_present) feedback_write = table.retired(commit.hit, commit.eligible, resolution_busy);
    commit_present = false;
    // Stale/ineligible feedback uses no write; an idle port can bypass to a hint.
    if (!resolution_busy && !feedback_write) hint_tick(bht);
  }
  void gap_ticks(uint32_t clocks, const std::array<unsigned, 16> &bht) {
    while (clocks-- && hint_count) hint_tick(bht);
  }
  void invalidate() {
    table.clear(); hint_count = hint_head = 0;
    queries.clear(); retirements.clear(); commit_present = false;
  }
};

struct CacheLine {
  uint32_t base = 0;
  unsigned mask = 0;
  bool present = false;
  std::array<uint32_t, 8> words{};
};

static bool direct_hint(uint32_t pc, uint32_t word, Hint &hint, int32_t &displacement) {
  unsigned opcode = word & 127;
  if (opcode == 0x63) {
    unsigned function = (word >> 12) & 7;
    if (function == 2 || function == 3) return false;
    uint32_t imm = ((word >> 31) << 12) | (((word >> 7) & 1) << 11) |
                   (((word >> 25) & 63) << 5) | (((word >> 8) & 15) << 1);
    displacement = (imm & 4096) ? int32_t(imm) - 8192 : int32_t(imm);
    hint = {pc, pc + uint32_t(displacement), 0};
    return true;
  }
  if (opcode == 0x6f) {
    uint32_t imm = ((word >> 31) << 20) | (((word >> 12) & 255) << 12) |
                   (((word >> 20) & 1) << 11) | (((word >> 21) & 1023) << 1);
    displacement = (imm & (1u << 20)) ? int32_t(imm) - (1 << 21) : int32_t(imm);
    hint = {pc, pc + uint32_t(displacement), 1};
    return true;
  }
  return false;
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  std::ifstream configurations(argv[1]), input(argv[2], std::ios::binary);
  if (!configurations || !input) throw std::runtime_error("Input file missing");
  std::vector<Experiment> experiments;
  std::string line;
  while (std::getline(configurations, line)) {
    std::replace(line.begin(), line.end(), ',', ' ');
    std::istringstream fields(line);
    unsigned id, entries, ways, index, admission, width, policy, prefill, direction;
    if (!(fields >> id >> entries >> ways >> index >> admission >> width >> policy >> prefill >> direction))
      throw std::runtime_error("Configuration malformed");
    experiments.emplace_back(id, ReplacementConfig{entries, ways, index, admission, width, Replacement(policy)}, prefill, direction);
  }
  std::array<CacheLine, 32> cache;
  std::array<unsigned, 16> bht; bht.fill(1);
  std::vector<uint32_t> ras;
  std::vector<Event> events;
  Event event;
  while (input.read(reinterpret_cast<char *>(&event), sizeof(event))) events.push_back(event);
  uint64_t query_checks = 0;
  for (size_t first = 0; first < events.size();) {
    size_t last = first + 1;
    while (last < events.size() && events[last].cycle == events[first].cycle) ++last;
    if (first) {
      if (events[first].cycle <= events[first - 1].cycle) throw std::runtime_error("Nonmonotonic clock");
      unsigned gap = events[first].cycle - events[first - 1].cycle - 1;
      for (auto &experiment : experiments) experiment.gap_ticks(gap, bht);
    }
    bool resolution_busy = false;
    for (size_t i = first; i < last; ++i) {
      const auto &e = events[i];
      if (e.operation == 0) {
        if (bool(e.directions & 1) != bool(bht[(e.pc >> 2) & 15] >> 1))
          throw std::runtime_error("BHT predictor state drift");
        for (auto &experiment : experiments) experiment.query(e, ras);
        ++query_checks;
      } else if (e.operation == 1) {
        resolution_busy = true;
        for (auto &experiment : experiments) experiment.resolve(e);
        if (e.kind == 0) {
          auto &counter = bht[(e.pc >> 2) & 15];
          counter = e.taken ? std::min(3u, counter + 1) : counter ? counter - 1 : 0;
        }
        if (e.taken) {
          if ((e.call_hints & 1) && !ras.empty()) ras.pop_back();
          if (e.call_hints & 2) {
            if (ras.size() == 4) ras.erase(ras.begin());
            ras.push_back(e.pc + 4);
          }
        }
      } else if (e.operation == 2) {
        for (auto &experiment : experiments) experiment.retire(e.id);
      } else if (e.operation == 7) {
        for (auto &experiment : experiments) experiment.squash(e.id);
      }
    }
    for (auto &experiment : experiments) experiment.finish_edge(resolution_busy, bht);
    std::vector<unsigned> installs;
    for (size_t i = first; i < last; ++i) {
      const auto &e = events[i];
      if (e.operation >= 3 && e.operation <= 5) {
        if (e.id >= 8 || e.target >= 4) throw std::runtime_error("Wrong I-cache geometry");
        unsigned slot = 4 * e.id + e.target;
        auto &row = cache[slot];
        if (e.operation == 3) { row.base = e.pc; row.mask = 0; row.present = false; }
        if (e.operation == 4) { row.words.at(e.kind) = e.pc; row.mask |= 1u << e.kind; }
        if (e.operation == 5) {
          if (row.base != e.pc) throw std::runtime_error("Cache install identity drift");
          row.present = true;
          installs.push_back(slot);
        }
      } else if (e.operation == 6) {
        cache = {}; installs.clear(); ras.clear();
        for (auto &experiment : experiments) experiment.invalidate();
      }
    }
    for (unsigned slot : installs) {
      const auto &row = cache[slot];
      if (row.mask != 255) throw std::runtime_error("Hint source installed before all words arrived");
      for (unsigned word = 0; word < 8; ++word) {
        Hint hint{}; int32_t displacement;
        if (direct_hint(row.base + 4 * word, row.words[word], hint, displacement))
          for (auto &experiment : experiments) experiment.hint_enqueue(hint, displacement);
      }
    }
    first = last;
  }
  std::cout << "id,branches,conditional,direction_errors,next_pc_errors,taken,target_absent,target_wrong,hint_attempts,hint_dropped,confidence_rejected,query_snapshots_max,retirement_snapshots_max,inserts,evictions,hint_inserts,hint_evictions,unused_hint_evictions,hint_resolved_reuse,hint_retired_reuse,protected_hint_hits,rejected_targets,retire_updates,retire_stale,retire_busy,leader0_allocations,leader1_allocations,selector_final,query_checks\n";
  for (const auto &experiment : experiments) {
    if (!experiment.queries.empty()) throw std::runtime_error("Unresolved scored snapshot remains");
    const auto &c = experiment.counts; const auto &s = experiment.table.stats;
    std::cout << experiment.id << ',' << c.branches << ',' << c.conditional << ',' << c.direction_errors
      << ',' << c.next_pc_errors << ',' << c.taken << ',' << c.target_absent << ',' << c.target_wrong
      << ',' << c.hint_attempts << ',' << c.hint_dropped << ',' << c.confidence_rejected
      << ',' << c.query_snapshots_max << ',' << c.retirement_snapshots_max
      << ',' << s.inserts << ',' << s.evictions << ',' << s.hint_inserts << ',' << s.hint_evictions
      << ',' << s.unused_hint_evictions << ',' << s.hint_resolved_reuse << ',' << s.hint_retired_reuse
      << ',' << s.protected_hint_hits << ',' << s.rejected_targets << ',' << s.retire_updates
      << ',' << s.retire_stale << ',' << s.retire_busy << ',' << s.leader0_allocations
      << ',' << s.leader1_allocations << ',' << experiment.table.selector() << ',' << query_checks << '\n';
  }
}
