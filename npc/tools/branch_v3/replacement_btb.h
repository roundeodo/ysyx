#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <stdexcept>
#include <vector>

// Finite policy state. Lookup is read-only; updates occur at resolution or at
// explicitly granted retirement feedback. No method receives future outcomes.
enum class Replacement {
  RoundRobin, LruTaken, LruAny, TreePlru, Lip, Bip, Dip, Srrip,
  RripInsert3, Brrip, Drrip, ShipResolve, RetireTaken, RetireUseful
};

struct ReplacementConfig {
  unsigned entries, ways, index, admission, target_bits;
  Replacement policy;
};

struct ReplacementHit {
  bool present = false;
  uint32_t pc = 0, target = 0;
  unsigned kind = 0, set = 0, way = 0, generation = 0;
  uint64_t diagnostic_version = 0;
};

struct ReplacementStats {
  uint64_t inserts = 0, evictions = 0, hint_inserts = 0;
  uint64_t hint_evictions = 0, unused_hint_evictions = 0;
  uint64_t hint_resolved_reuse = 0, hint_retired_reuse = 0;
  uint64_t protected_hint_hits = 0, rejected_targets = 0;
  uint64_t retire_updates = 0, retire_stale = 0, retire_busy = 0;
  uint64_t leader0_allocations = 0, leader1_allocations = 0;
};

class ReplacementBtb {
 public:
  struct Entry {
    bool present = false;
    uint32_t pc = 0, payload = 0;
    unsigned kind = 0, age = 3, rank = 0, generation = 0;
    bool hint = false, resolved_reuse = false, retired_reuse = false;
    bool ship_outcome = false;
    // This unbounded version is an evaluator assertion, not policy input.
    uint64_t diagnostic_version = 0;
  };

  explicit ReplacementBtb(ReplacementConfig config) : config_(config),
      rows_(config.entries / config.ways, std::vector<Entry>(config.ways)),
      next_(rows_.size(), 0), tree_(rows_.size(), 0) {
    if (config.ways < 2 || (config.ways & (config.ways - 1)) ||
        config.entries % config.ways || rows_.size() < 2 ||
        (rows_.size() & (rows_.size() - 1)) || config.index > 2 ||
        (config.target_bits != 16 && config.target_bits != 32))
      throw std::runtime_error("Invalid finite replacement topology");
    for (auto &row : rows_) for (unsigned way = 0; way < config.ways; ++way)
      row[way].rank = way;
    signatures_.fill(1);
  }

  unsigned index(uint32_t pc) const {
    unsigned bits = bits_for(rows_.size());
    uint32_t word = pc >> 2, value = word;
    if (config_.index == 1) value ^= word >> bits;
    if (config_.index == 2)
      for (unsigned shift = bits; shift < 30; shift += bits) value ^= word >> shift;
    return value & (rows_.size() - 1);
  }

  ReplacementHit lookup(uint32_t pc) const {
    unsigned set = index(pc);
    for (unsigned way = 0; way < config_.ways; ++way) {
      const auto &entry = rows_[set][way];
      if (entry.present && entry.pc == pc) return snapshot(set, way);
    }
    return {};
  }

  ReplacementHit train(uint32_t pc, uint32_t target, unsigned kind,
                       bool taken, bool hint = false, bool hint_low = false) {
    unsigned set = index(pc);
    auto &row = rows_[set];
    int hit = -1, empty = -1;
    for (unsigned way = 0; way < config_.ways; ++way) {
      if (row[way].present && row[way].pc == pc) hit = way;
      if (!row[way].present && empty < 0) empty = way;
    }
    if (hint && hit >= 0) {
      ++stats.protected_hint_hits;
      return snapshot(set, hit);
    }
    if (hit < 0 && config_.admission == 2 && kind == 0 && !taken) return {};
    if (config_.target_bits == 16 && (pc >> 16) != (target >> 16)) {
      ++stats.rejected_targets;
      if (hit >= 0) invalidate_entry(row[hit]);
      return {};
    }
    unsigned selected = hit >= 0 ? hit : empty >= 0 ? empty : victim(set);
    auto &entry = row[selected];
    bool allocation = hit < 0, replacement = allocation && entry.present;
    if (replacement) {
      ++stats.evictions;
      if (entry.hint) {
        ++stats.hint_evictions;
        stats.unused_hint_evictions += !entry.resolved_reuse;
      }
      if (config_.policy == Replacement::ShipResolve && !entry.ship_outcome) {
        auto &counter = signatures_[signature(entry.pc)];
        if (counter) --counter;
      }
    }
    if (allocation) {
      ++stats.inserts;
      stats.hint_inserts += hint;
      // Allocation/eviction version is separate from target updates on hits.
      entry.generation = (entry.generation + 1) & 15;
      ++entry.diagnostic_version;
      entry.hint = hint;
      entry.resolved_reuse = entry.retired_reuse = entry.ship_outcome = false;
      if (!hint && (config_.policy == Replacement::Dip || config_.policy == Replacement::Drrip)) {
        if (set == 0) {
          selector_ = std::min(31u, selector_ + 1);
          ++stats.leader0_allocations;
        } else if (set == rows_.size() / 2) {
          if (selector_) --selector_;
          ++stats.leader1_allocations;
        }
      }
    } else if (taken && entry.hint && !entry.resolved_reuse) {
      entry.resolved_reuse = true;
      ++stats.hint_resolved_reuse;
    }

    switch (config_.policy) {
      case Replacement::RoundRobin:
        if (replacement) next_[set] = (selected + 1) % config_.ways;
        break;
      case Replacement::LruTaken:
      case Replacement::LruAny:
      case Replacement::Lip:
      case Replacement::Bip:
      case Replacement::Dip:
        if (allocation) {
          bool low = hint && hint_low;
          low |= config_.policy == Replacement::Lip;
          if (config_.policy == Replacement::Bip ||
              (config_.policy == Replacement::Dip && adaptive_alternative(set)))
            low |= phase_ != 0;
          rank_insert(set, selected, low ? config_.ways - 1 : 0);
        } else if (taken || config_.policy == Replacement::LruAny) {
          rank_insert(set, selected, 0);
        }
        break;
      case Replacement::TreePlru:
        if (allocation || taken) tree_touch(set, selected, hint && hint_low);
        break;
      default:
        if (allocation) {
          if (empty < 0) {
            unsigned maximum = row[selected].age;
            for (auto &old : row) old.age += 3 - maximum;
          }
          unsigned insertion = 2;
          if (config_.policy == Replacement::RripInsert3) insertion = 3;
          if (config_.policy == Replacement::Brrip ||
              (config_.policy == Replacement::Drrip && adaptive_alternative(set)))
            insertion = phase_ == 0 ? 2 : 3;
          if (config_.policy == Replacement::ShipResolve)
            insertion = signatures_[signature(pc)] ? 2 : 3;
          if (hint && hint_low) insertion = 3;
          entry.age = insertion;
        } else if (taken && !retirement_policy()) {
          entry.age = 0;
        }
        break;
    }
    if (!allocation && taken && config_.policy == Replacement::ShipResolve) {
      auto &counter = signatures_[signature(entry.pc)];
      counter = std::min(3u, counter + 1);
      entry.ship_outcome = true;
    }
    if (allocation && (config_.policy == Replacement::Bip || config_.policy == Replacement::Dip ||
                       config_.policy == Replacement::Brrip || config_.policy == Replacement::Drrip))
      phase_ = (phase_ + 1) & 31;
    entry.present = true;
    entry.pc = pc;
    entry.payload = config_.target_bits == 16 ? target & 65535 : target;
    entry.kind = kind;
    return snapshot(set, selected);
  }

  bool retired(const ReplacementHit &saved, bool eligible, bool port_busy) {
    if (!saved.present || !eligible) return false;
    auto &entry = rows_[saved.set][saved.way];
    bool current = entry.present && entry.pc == saved.pc && entry.generation == saved.generation;
    if (current && entry.diagnostic_version != saved.diagnostic_version)
      throw std::runtime_error("Four-bit generation wrapped over a live query snapshot");
    if (retirement_policy() && port_busy) {
      ++stats.retire_busy;
      return false;
    }
    if (!current) {
      if (retirement_policy()) ++stats.retire_stale;
      return false;
    }
    if (entry.hint && !entry.retired_reuse) {
      entry.retired_reuse = true;
      ++stats.hint_retired_reuse;
    }
    if (retirement_policy()) {
      entry.age = 0;
      ++stats.retire_updates;
      return true;
    }
    return false;
  }

  void clear() {
    for (auto &row : rows_) for (unsigned way = 0; way < config_.ways; ++way) {
      invalidate_entry(row[way]);
      row[way].age = 3;
      row[way].rank = way;
    }
    std::fill(next_.begin(), next_.end(), 0);
    std::fill(tree_.begin(), tree_.end(), 0);
    signatures_.fill(1);
    phase_ = 0;
    selector_ = 16;
  }

  bool retirement_policy() const {
    return config_.policy == Replacement::RetireTaken || config_.policy == Replacement::RetireUseful;
  }
  Replacement policy() const { return config_.policy; }
  const std::vector<std::vector<Entry>> &rows() const { return rows_; }
  unsigned selector() const { return selector_; }
  ReplacementStats stats;

 private:
  static unsigned bits_for(unsigned count) {
    unsigned bits = 0;
    while ((1u << bits) < count) ++bits;
    return bits;
  }
  static unsigned signature(uint32_t pc) {
    uint32_t word = pc >> 2, folded = 0;
    for (unsigned shift = 0; shift < 30; shift += 4) folded ^= word >> shift;
    return folded & 15;
  }
  static void invalidate_entry(Entry &entry) {
    entry.present = false;
    entry.generation = (entry.generation + 1) & 15;
    ++entry.diagnostic_version;
  }
  ReplacementHit snapshot(unsigned set, unsigned way) const {
    const auto &entry = rows_[set][way];
    uint32_t target = config_.target_bits == 16 ? (entry.pc & 0xffff0000) | entry.payload : entry.payload;
    return {entry.present, entry.pc, target, entry.kind, set, way, entry.generation, entry.diagnostic_version};
  }
  bool adaptive_alternative(unsigned set) const {
    if (set == 0) return false;
    if (set == rows_.size() / 2) return true;
    return selector_ >= 16;
  }
  unsigned victim(unsigned set) const {
    const auto &row = rows_[set];
    switch (config_.policy) {
      case Replacement::RoundRobin: return next_[set];
      case Replacement::LruTaken:
      case Replacement::LruAny:
      case Replacement::Lip:
      case Replacement::Bip:
      case Replacement::Dip:
        for (unsigned way = 0; way < config_.ways; ++way)
          if (row[way].rank == config_.ways - 1) return way;
        throw std::runtime_error("LRU rank permutation broken");
      case Replacement::TreePlru: {
        unsigned node = 0, way = 0;
        for (unsigned level = 0; level < bits_for(config_.ways); ++level) {
          unsigned direction = (tree_[set] >> node) & 1;
          way = (way << 1) | direction;
          node = 2 * node + 1 + direction;
        }
        return way;
      }
      default: {
        unsigned selected = 0;
        for (unsigned way = 1; way < config_.ways; ++way)
          if (row[way].age > row[selected].age) selected = way;
        return selected;
      }
    }
  }
  void rank_insert(unsigned set, unsigned selected, unsigned rank) {
    unsigned old_rank = rows_[set][selected].rank;
    for (unsigned way = 0; way < config_.ways; ++way) {
      if (way == selected) continue;
      auto &value = rows_[set][way].rank;
      if (rank < old_rank && value >= rank && value < old_rank) ++value;
      if (rank > old_rank && value > old_rank && value <= rank) --value;
    }
    rows_[set][selected].rank = rank;
  }
  void tree_touch(unsigned set, unsigned way, bool low_priority) {
    unsigned node = 0, levels = bits_for(config_.ways);
    for (unsigned level = 0; level < levels; ++level) {
      unsigned direction = (way >> (levels - level - 1)) & 1;
      unsigned value = low_priority ? direction : direction ^ 1;
      tree_[set] = (tree_[set] & ~(1u << node)) | (value << node);
      node = 2 * node + 1 + direction;
    }
  }

  ReplacementConfig config_;
  std::vector<std::vector<Entry>> rows_;
  std::vector<unsigned> next_, tree_;
  std::array<unsigned, 16> signatures_;
  unsigned phase_ = 0, selector_ = 16;
};
