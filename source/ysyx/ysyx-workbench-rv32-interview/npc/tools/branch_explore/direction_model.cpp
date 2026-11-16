// Correct-path, immediate-update screening. No CPU timing or speculative costs.
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

struct Entry { bool present=false; unsigned tag=0, counter=0, useful=0; };
struct Loop { bool present=false, overflow=false; uint32_t pc=0; unsigned current=0, trip=0, confidence=0; };
unsigned folded(uint32_t value, unsigned bits, unsigned length) {
  value &= (1u<<length)-1; unsigned result=0;
  while(value) { result ^= value & ((1u<<bits)-1); value >>= bits; }
  return result;
}
unsigned saturate(unsigned counter, bool taken, unsigned maximum) {
  return taken ? std::min(maximum,counter+1) : counter ? counter-1 : 0;
}
struct Predictor {
  std::string name;
  char kind;
  unsigned n, h, bits, variant, index_bits=0;
  uint32_t history=0;
  std::vector<unsigned> base, local;
  std::array<std::vector<Entry>,3> banks;
  std::vector<std::vector<int>> weights;
  std::vector<Loop> loops;
  unsigned victim=0;
  uint64_t errors=0, false_taken=0, branches=0;
  Predictor(std::string name_,char kind_,unsigned n_,unsigned h_=0,unsigned variant_=0):
    name(name_),kind(kind_),n(n_),h(h_),variant(variant_) {
    while((1u<<index_bits)<n)++index_bits;
    if(kind=='T') { base.assign(n,1);for(auto &bank:banks)bank.resize(n);bits=41*n+16; }
    else if(kind=='L') { local.assign(n,0);base.assign(1u<<h,1);bits=n*h+2*base.size(); }
    else if(kind=='P') {weights.assign(n,std::vector<int>(h+1,0));bits=n*(h+1)*8+h;}
    else if(kind=='O') {base.assign(64,1);loops.resize(n);bits=128+n*50+index_bits;}
    else {base.assign(n,1);bits=2*n+h;}
  }
  void step(uint32_t pc,bool taken,uint32_t target) {
    bool predicted=false;
    if(kind=='T') {
      std::array<unsigned,3> indices,tags;
      for(unsigned b=0;b<3;++b) {
        unsigned length=4u<<b;
        indices[b]=((pc>>2)^folded(history,index_bits,length))&(n-1);
        tags[b]=((pc>>2)^(pc>>10)^folded(history,8,length)^(folded(history,7,length)<<1))&255;
      }
      unsigned base_index=(pc>>2)&(n-1),provider=0,alternate_provider=0;
      bool alternate=base[base_index]>=2;
      predicted=alternate;
      for(unsigned b=0;b<3;++b) {
        auto &entry=banks[b][indices[b]];
        if(entry.present && entry.tag==tags[b]) {
          alternate_provider=provider;alternate=predicted;provider=b+1;predicted=entry.counter>=4;
        }
      }
      bool base_prediction=base[base_index]>=2;
      base[base_index]=saturate(base[base_index],taken,3);
      if(provider) {
        auto &entry=banks[provider-1][indices[provider-1]];
        entry.counter=saturate(entry.counter,taken,7);
        if(predicted!=alternate)entry.useful=predicted==taken;
      }
      if(variant==1 && alternate_provider && predicted!=taken && alternate==taken)
        banks[alternate_provider-1][indices[alternate_provider-1]].useful=1;
      if(predicted!=taken && (variant!=2 || base_prediction!=taken)) {
        int allocation=-1;
        for(unsigned b=provider;b<3;++b) {
          auto &entry=banks[b][indices[b]];
          if(allocation<0 && (!entry.present || !entry.useful))allocation=b;
        }
        if(allocation>=0)banks[allocation][indices[allocation]]={true,tags[allocation],taken?4u:3u,0};
        else for(unsigned b=provider;b<3;++b)banks[b][indices[b]].useful=0;
      }
      history=((history<<1)|taken)&65535;
    } else if(kind=='P') {
      auto &row=weights[(pc>>2)&(n-1)];int score=row[0];
      for(unsigned b=0;b<h;++b)score+=row[b+1]*((history>>b)&1 ? 1:-1);
      predicted=score>=0;
      if(predicted!=taken || std::abs(score)<=int(1.93*h+14)) {
        int sign=taken?1:-1;row[0]=std::clamp(row[0]+sign,-128,127);
        for(unsigned b=0;b<h;++b)row[b+1]=std::clamp(row[b+1]+sign*(((history>>b)&1)?1:-1),-128,127);
      }
      history=((history<<1)|taken)&((1u<<h)-1);
    } else if(kind=='O') {
      unsigned index=(pc>>2)&63;predicted=base[index]>=2;
      Loop *entry=nullptr;
      if(target<pc)for(auto &e:loops)if(e.present && e.pc==pc){entry=&e;break;}
      if(entry && entry->confidence==3 && !entry->overflow)predicted=entry->current<entry->trip;
      base[index]=saturate(base[index],taken,3);
      if(target<pc) {
        if(!entry) {
          unsigned slot=victim;
          for(unsigned i=0;i<n;++i)if(!loops[i].present){slot=i;break;}
          if(loops[slot].present)victim=(slot+1)%n;
          loops[slot]={true,false,pc,0,0,0};entry=&loops[slot];
        }
        if(taken) {
          if(entry->current==255){entry->overflow=true;entry->confidence=0;}
          else {++entry->current;if(entry->current>entry->trip)entry->confidence=0;}
        } else {
          if(!entry->overflow && entry->current>0) {
            if(entry->current==entry->trip)entry->confidence=std::min(3u,entry->confidence+1);
            else {entry->trip=entry->current;entry->confidence=0;}
          } else entry->confidence=0;
          entry->current=0;entry->overflow=false;
        }
      }
    } else {
      unsigned row=(pc>>2)&(n-1);
      unsigned index=kind=='L' ? local[row] : ((pc>>2)^history)&(n-1);
      predicted=base[index]>=2;base[index]=saturate(base[index],taken,3);
      if(kind=='L')local[row]=((local[row]<<1)|taken)&((1u<<h)-1);
      else history=h ? ((history<<1)|taken)&((1u<<h)-1) : 0;
    }
    ++branches;errors+=predicted!=taken;false_taken+=predicted && !taken;
  }
};
int main(int argc,char **argv) {
  if(argc!=2)return 2;
  std::vector<Predictor> predictors;
  for(unsigned n:{16,64,128,256,512,1024}) {
    unsigned h=0;while((1u<<h)<n)++h;
    predictors.emplace_back("bimodal"+std::to_string(n),'B',n);
    predictors.emplace_back("gshare"+std::to_string(n),'G',n,h);
  }
  for(unsigned n:{8,16,32})for(unsigned v=0;v<3;++v)
    predictors.emplace_back("tage"+std::to_string(n)+(v==1?"-alt":v==2?"-selective":""),'T',n,16,v);
  for(unsigned n:{16,32,64})for(unsigned h:{4,8})
    predictors.emplace_back("local"+std::to_string(n)+"-h"+std::to_string(h),'L',n,h);
  for(unsigned n:{4,8,16})predictors.emplace_back("perceptron"+std::to_string(n),'P',n,16);
  for(unsigned n:{4,8})predictors.emplace_back("loop"+std::to_string(n),'O',n);
  std::ifstream input(argv[1]);if(!input)return 3;
  std::string line;uint64_t instructions=0;
  while(std::getline(input,line)) {
    std::replace(line.begin(),line.end(),',',' ');std::istringstream row(line);
    uint32_t pc,insn,next;uint64_t cycle;
    if(!(row>>std::hex>>pc>>insn>>next>>std::dec>>cycle))return 4;
    ++instructions;if((insn&127)!=0x63)continue;
    unsigned imm=((insn>>31)<<12)|(((insn>>7)&1)<<11)|(((insn>>25)&63)<<5)|(((insn>>8)&15)<<1);
    int32_t signed_imm=(imm&4096)?int32_t(imm)-8192:int32_t(imm);
    uint32_t target=pc+signed_imm;bool taken=next!=pc+4;
    for(auto &predictor:predictors)predictor.step(pc,taken,target);
  }
  for(auto &p:predictors)std::cout<<p.name<<','<<p.bits<<','<<p.errors<<','<<p.false_taken<<','<<p.branches<<','<<instructions<<'\n';
}
