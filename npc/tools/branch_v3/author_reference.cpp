// CBP 2016 adapter; the author's predictor.h remains unmodified.
#include <cstdint>
#include <iostream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>
#include "predictor.h"

int main() {
  PREDICTOR predictor;
  uint64_t count = 0, errors = 0, total = 0;
  std::vector<std::pair<uint64_t, uint64_t>> learning;
  std::string line;
  // Kind: conditional, direct, indirect, direct-call, return, indirect-call.
  // Optional fifth field controls scoring only; unscored prefix still trains.
  while (std::getline(std::cin, line)) {
    uint64_t pc, target;
    unsigned kind, taken, scored = 1;
    std::istringstream input(line);
    if (!(input >> std::hex >> pc >> target >> std::dec >> kind >> taken)) return 2;
    input >> scored;
    if (kind == 0) {
      const bool prediction = predictor.GetPrediction(pc);
      ++total;
      if (scored) {
        errors += prediction != bool(taken);
        ++count;
        if (count % 4096 == 0) learning.emplace_back(count, errors);
      }
      predictor.UpdatePredictor(pc, OPTYPE_JMP_DIRECT_COND, taken, prediction, target);
    } else {
      const OpType op = kind == 1 ? OPTYPE_JMP_DIRECT_UNCOND :
                        kind == 3 ? OPTYPE_CALL_DIRECT_UNCOND :
                        kind == 4 ? OPTYPE_RET_UNCOND :
                        kind == 5 ? OPTYPE_CALL_INDIRECT_UNCOND : OPTYPE_JMP_INDIRECT_UNCOND;
      predictor.TrackOtherInst(pc, op, taken, target);
    }
  }
  std::cout << "{\"conditional\":" << count << ",\"total_conditional\":" << total
            << ",\"errors\":" << errors << ",\"learning\":[";
  for (size_t i = 0; i < learning.size(); ++i) {
    if (i) std::cout << ',';
    std::cout << '[' << learning[i].first << ',' << learning[i].second << ']';
  }
  std::cout << "],\"model\":\"M0-author-CBP2016-8KB-immediate-training\"}\n";
}
