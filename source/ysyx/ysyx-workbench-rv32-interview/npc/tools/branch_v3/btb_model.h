// Software oracle stores full PCs. It deliberately does not reproduce RTL tag slicing.
#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <vector>

struct BtbConfig { unsigned entries, ways, index, policy, admission; };
struct BtbEntry { bool present=false; uint32_t pc=0, target=0; unsigned kind=0, reuse=3; bool reused=false; };
class BtbModel {
 public:
  BtbConfig config;
  std::vector<std::vector<BtbEntry>> rows;
  std::vector<unsigned> next;
  std::array<unsigned,16> signatures;
  explicit BtbModel(BtbConfig c): config(c), rows(c.entries/c.ways, std::vector<BtbEntry>(c.ways)), next(rows.size(),0) {signatures.fill(1);}
  unsigned signature(uint32_t pc) const {
    uint32_t word=pc>>2, folded=0;
    for(unsigned shift=0;shift<30;shift+=4) folded ^= word>>shift;
    return folded & 15;
  }
  unsigned index(uint32_t pc) const {
    unsigned bits=0; while((1u<<bits)<rows.size()) ++bits;
    uint32_t word=pc>>2, value=word;
    if(config.index==1) value ^= word>>bits;
    if(config.index==2) for(unsigned shift=bits;shift<30;shift+=bits) value ^= word>>shift;
    return value & (rows.size()-1);
  }
  const BtbEntry* lookup(uint32_t pc) const {
    for(const auto &entry:rows[index(pc)]) if(entry.present && entry.pc==pc) return &entry;
    return nullptr;
  }
  void clear() { for(auto &row:rows) for(auto &e:row) {e.present=false;e.reuse=3;e.reused=false;} std::fill(next.begin(),next.end(),0); signatures.fill(1); }
  void train(uint32_t pc,uint32_t target,unsigned kind,bool taken) {
    unsigned set=index(pc); auto &row=rows[set]; int hit=-1, empty=-1;
    for(unsigned w=0;w<config.ways;++w) {
      if(row[w].present && row[w].pc==pc) hit=w;
      if(!row[w].present && empty<0) empty=w;
    }
    bool admit_all=config.admission==1 || (config.admission==0 && config.policy==0);
    if(hit<0 && !admit_all && kind==0 && !taken) return;
    unsigned victim=next[set], maximum=0;
    if(config.policy==2 || config.policy==4) {
      victim=0; maximum=row[0].reuse;
      for(unsigned w=1;w<config.ways;++w) if(row[w].reuse>maximum) {maximum=row[w].reuse;victim=w;}
    }
    unsigned selected=hit>=0 ? hit : empty>=0 ? empty : victim;
    if(config.policy==4 && hit<0 && empty<0 && !row[selected].reused) {
      auto &counter=signatures[signature(row[selected].pc)]; if(counter) --counter;
    }
    if(config.policy==2 || config.policy==4) {
      if(hit<0) {
        if(empty<0) for(auto &e:row) e.reuse += 3-maximum;
        row[selected].reuse=(config.policy==4 && !signatures[signature(pc)]) ? 3 : 2;
      } else if(taken) row[selected].reuse=0;
    }
    if(config.policy==4) {
      if(hit<0) row[selected].reused=false;
      else if(taken) {
        row[selected].reused=true;
        auto &counter=signatures[signature(pc)]; counter=std::min(3u,counter+1);
      }
    }
    auto &entry=row[selected]; entry.present=true;entry.pc=pc;entry.target=target;entry.kind=kind;
    if((config.policy<2 && hit<0 && empty<0) || (config.policy==3 && (hit<0 || taken))) next[set]=(selected+1)%config.ways;
  }
};
