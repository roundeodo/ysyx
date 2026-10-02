#include "btb_model.h"
#include <array>
#include <fstream>
#include <iostream>
#include <list>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>
// Record: operation, PC, target, kind, taken, ROI, observed hit, target, kind.
using Event=std::array<uint32_t,9>;
struct Counts { uint64_t queries=0,taken=0,absent=0,wrong=0,cold=0,pending=0,unadmitted=0,fa_hit=0,fa_miss=0; };
int main(int argc,char**argv) {
  if(argc!=2) return 2;
  std::ifstream in(argv[1],std::ios::binary);std::vector<Event> events;Event event;
  while(in.read(reinterpret_cast<char*>(event.data()),sizeof(event))) events.push_back(event);
  for(unsigned entries:{16u,32u,64u,128u}) for(unsigned ways:{2u,4u}) for(unsigned index:{0u,1u,2u})
  for(unsigned policy:{0u,2u,3u}) for(unsigned admission:{1u,2u}) {
    if(policy==3 && ways!=2) continue;
    BtbModel model({entries,ways,index,policy,admission});Counts count;
    std::unordered_set<uint32_t> queried,resolved,admitted;
    std::list<uint32_t> fa;std::unordered_map<uint32_t,std::list<uint32_t>::iterator> fa_map;
    bool baseline=entries==16&&ways==2&&index==0&&policy==0&&admission==1;
    for(const auto &e:events) {
      auto [op,pc,target,kind,taken,roi,observed_hit,observed_target,observed_kind]=e;
      if(op==0) {
        const auto *found=model.lookup(pc);
        if(baseline && (bool(found)!=bool(observed_hit) || (found&&(found->target!=observed_target||found->kind!=observed_kind))))
          throw std::runtime_error("full-prefix baseline BTB query mismatch");
        if(roi) {
          ++count.queries;
          if(taken) {
            ++count.taken;
            if(!found) {
              ++count.absent;
              if(!resolved.count(pc)) { if(queried.count(pc)) ++count.pending;else ++count.cold; }
              else if(!admitted.count(pc)) ++count.unadmitted;
              else if(fa_map.count(pc)) ++count.fa_hit;
              else ++count.fa_miss;
            } else if(found->target!=target) ++count.wrong;
          }
        }
        queried.insert(pc);
      } else {
        model.train(pc,target,kind,taken);resolved.insert(pc);
        if(model.lookup(pc)) admitted.insert(pc);
        // Same-capacity fully associative LRU shadow, same admission policy.
        auto it=fa_map.find(pc);
        if(it!=fa_map.end()) { if(taken) {fa.erase(it->second);fa.push_front(pc);it->second=fa.begin();} }
        else if(admission==1||kind!=0||taken) {
          if(fa.size()==entries) {fa_map.erase(fa.back());fa.pop_back();}
          fa.push_front(pc);fa_map[pc]=fa.begin();
        }
      }
    }
    std::cout<<entries<<','<<ways<<','<<index<<','<<policy<<','<<admission<<','<<count.queries<<','<<count.taken<<','<<count.absent<<','<<count.wrong<<','<<count.cold<<','<<count.pending<<','<<count.unadmitted<<','<<count.fa_hit<<','<<count.fa_miss<<'\n';
  }
}
