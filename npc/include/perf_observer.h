#pragma once
#include <cstdint>
#include <cstdio>
#include <deque>

// Samples remain in acceptance order until their loads retire. All counters
// describe the state before the sample edge: [start_edge, end_edge).
struct PerfTimerSample {
  uint64_t cycle = 0, retired = 0, ticks = 0, load_pc = 0, return_pc = 0;
  uint64_t interrupts = 0;
};

class PerfObserver {
 public:
  void open(const char *path, uint64_t cpu_hz, uint64_t timer_hz);
  bool enabled() const { return output_ != nullptr; }
  void sample(const PerfTimerSample &sample);
  void commit(uint64_t cycle, uint64_t pc, uint32_t instruction, bool retired);
  void finish(uint64_t cycles, uint64_t retired, uint64_t interrupts,
              uint64_t clint_writes, bool good_exit);
 private:
  FILE *output_ = nullptr;
  bool valid_ = true;
  std::deque<PerfTimerSample> pending_samples_;
};
