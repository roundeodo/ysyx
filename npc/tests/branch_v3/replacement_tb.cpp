#include "btb_model.h"
#include "replacement_btb.h"
#include <cassert>
#include <iostream>
#include <random>
#include <set>

static uint32_t pc(unsigned tag) { return 0x80000000u + tag * 32; }

int main() {
  uint64_t checks = 0;
  // Cross-check existing rules against the independently used legacy model,
  // including complete entry/reuse state, invalidate and same-PC target changes.
  for (unsigned ways : {2u, 4u}) for (unsigned index : {0u, 1u, 2u})
  for (unsigned admission : {1u, 2u}) for (unsigned policy : {0u, 2u, 3u}) {
    if (policy == 3 && ways != 2) continue;
    auto rule = policy == 0 ? Replacement::RoundRobin : policy == 2 ? Replacement::Srrip : Replacement::LruTaken;
    BtbModel old({32, ways, index, policy, admission});
    ReplacementBtb now({32, ways, index, admission, 32, rule});
    std::mt19937 rng(3571 + policy);
    for (unsigned event = 0; event < 3000; ++event) {
      uint32_t address = pc(rng() % 97), target = rng();
      unsigned kind = rng() % 4; bool taken = rng() & 1;
      auto expected = old.lookup(address); auto actual = now.lookup(address);
      assert(actual.present == bool(expected));
      if (expected) assert(actual.target == expected->target && actual.kind == expected->kind);
      old.train(address, target, kind, taken); now.train(address, target, kind, taken);
      for (unsigned set = 0; set < old.rows.size(); ++set) for (unsigned way = 0; way < ways; ++way) {
        const auto &a = old.rows[set][way]; const auto &b = now.rows()[set][way];
        assert(a.present == b.present);
        if (a.present) assert(a.pc == b.pc && a.target == b.payload && a.kind == b.kind);
        if (policy == 2) assert(a.reuse == b.age);
        ++checks;
      }
      if (event % 137 == 0) { old.clear(); now.clear(); }
    }
  }
  // A four-way PLRU tree and true recency choose different victims after a hit.
  ReplacementBtb tree({32, 4, 0, 1, 32, Replacement::TreePlru});
  ReplacementBtb lru({32, 4, 0, 1, 32, Replacement::LruTaken});
  for (unsigned tag : {0u, 1u, 2u, 3u, 0u, 4u}) {
    tree.train(pc(tag), pc(tag) + 4, 1, true);
    lru.train(pc(tag), pc(tag) + 4, 1, true);
  }
  assert(!tree.lookup(pc(2)).present && tree.lookup(pc(1)).present);
  assert(!lru.lookup(pc(1)).present && lru.lookup(pc(2)).present);
  ReplacementBtb lip({32, 4, 0, 1, 32, Replacement::Lip});
  for (unsigned tag = 0; tag < 100; ++tag) lip.train(pc(tag), pc(tag) + 4, 1, true);
  assert(lip.lookup(pc(0)).present);  // One-pass cold insertions do not displace the initial hot position.
  ReplacementBtb brrip({32, 4, 0, 1, 32, Replacement::Brrip});
  for (unsigned tag = 0; tag < 65; ++tag) {
    auto hit = brrip.train(pc(tag), pc(tag) + 4, 1, true);
    assert(brrip.rows()[hit.set][hit.way].age == (tag % 32 == 0 ? 2u : 3u));
  }
  ReplacementBtb drrip({32, 4, 0, 1, 32, Replacement::Drrip});
  for (unsigned tag = 0; tag < 40; ++tag) drrip.train(pc(tag), pc(tag) + 4, 1, true);
  assert(drrip.selector() == 31 && drrip.stats.leader0_allocations == 40);
  for (unsigned tag = 0; tag < 40; ++tag) drrip.train(pc(tag) + 16, pc(tag) + 20, 1, true);
  assert(drrip.selector() == 0 && drrip.stats.leader1_allocations == 40);

  ReplacementBtb ship({16, 2, 0, 1, 32, Replacement::ShipResolve});
  // These four same-set PCs fold to the same signature. Dead residents lower
  // insertion confidence; an actual resolved reuse promotes the surviving row.
  ship.train(pc(0), pc(0) + 4, 1, true);
  ship.train(pc(17), pc(17) + 4, 1, true);
  auto distant = ship.train(pc(34), pc(34) + 4, 1, true);
  assert(ship.rows()[distant.set][distant.way].age == 3);
  ship.train(pc(34), pc(34) + 4, 1, true);
  assert(ship.rows()[distant.set][distant.way].age == 0);
  assert(ship.rows()[distant.set][distant.way].ship_outcome);

  ReplacementBtb retired({16, 2, 0, 1, 32, Replacement::RetireUseful});
  auto saved = retired.train(pc(0), pc(0) + 4, 1, true);
  assert(!retired.retired(saved, true, true));
  assert(retired.rows()[saved.set][saved.way].age == 2 && retired.stats.retire_busy == 1);
  assert(retired.retired(saved, true, false));
  assert(retired.rows()[saved.set][saved.way].age == 0);
  for (unsigned tag = 1; tag < 10; ++tag) retired.train(pc(tag), pc(tag) + 4, 1, true);
  assert(!retired.retired(saved, true, false) && retired.stats.retire_stale == 1);
  auto live = retired.lookup(pc(9)); retired.clear();
  assert(!retired.retired(live, true, false));
  ReplacementBtb narrow({16, 2, 0, 1, 16, Replacement::TreePlru});
  narrow.train(pc(0), 0x80001234, 1, true);
  assert(narrow.lookup(pc(0)).target == 0x80001234);
  narrow.train(pc(0), 0x81001234, 1, true);
  assert(!narrow.lookup(pc(0)).present && narrow.stats.rejected_targets == 1);
  // A hint never rewrites a resident identity/target, regardless of priority.
  narrow.train(pc(0), 0x80005678, 1, true);
  narrow.train(pc(0), 0x80009abc, 1, true, true, true);
  assert(narrow.lookup(pc(0)).target == 0x80005678);

  for (auto policy : {Replacement::LruTaken, Replacement::LruAny, Replacement::Lip, Replacement::Bip, Replacement::Dip}) {
    ReplacementBtb table({32, 4, 0, 1, 32, policy});
    std::mt19937 rng(1297);
    for (unsigned event = 0; event < 2000; ++event) {
      uint32_t address = pc(rng() % 53);
      table.train(address, address + 4, 0, rng() & 1, event % 5 == 0, event % 7 == 0);
      for (const auto &row : table.rows()) {
        std::set<unsigned> ranks;
        for (const auto &entry : row) ranks.insert(entry.rank);
        assert(ranks == std::set<unsigned>({0, 1, 2, 3}));
        ++checks;
      }
    }
  }
  std::cout << "PASS broader replacement: " << checks << " legacy-state/rank checks; PLRU, LIP, BRRIP, leaders, stale/busy retirement, compact range and hint protection\n";
}
