#include "perf_observer.h"
#include <cstdlib>
#include <inttypes.h>

void PerfObserver::open(const char *path, uint64_t cpu_hz, uint64_t timer_hz) {
  output_ = fopen(path, "wx");  // Never overwrite an earlier measurement.
  if (!output_) { perror("performance observer output"); exit(1); }
  fprintf(output_, "{\"type\":\"configuration\",\"schema\":1,\"cpu_hz\":%" PRIu64
          ",\"timer_hz\":%" PRIu64 ",\"boundary\":\"pre_rising_edge\"}\n",
          cpu_hz, timer_hz);
}

void PerfObserver::sample(const PerfTimerSample &sample) {
  if (!enabled()) return;
  if (pending_) valid_ = false;  // The current blocking LSU permits one sample.
  sample_ = sample;
  pending_ = true;
}

void PerfObserver::commit(uint64_t cycle, uint64_t pc, uint32_t instruction,
                          bool retired) {
  if (!enabled() || !pending_ || pc != sample_.load_pc) return;
  const bool successful_load = retired && (instruction & 0x707f) == 0x2003;
  valid_ &= successful_load;
  fprintf(output_, "{\"type\":\"timer_sample\",\"cycle\":%" PRIu64
          ",\"retired\":%" PRIu64 ",\"ticks\":%" PRIu64
          ",\"load_pc\":%" PRIu64 ",\"return_pc\":%" PRIu64
          ",\"interrupts\":%" PRIu64 ",\"load_commit_cycle\":%" PRIu64
          ",\"successful_load\":%s}\n", sample_.cycle, sample_.retired,
          sample_.ticks, sample_.load_pc, sample_.return_pc, sample_.interrupts,
          cycle, successful_load ? "true" : "false");
  fflush(output_);
  pending_ = false;
}

void PerfObserver::finish(uint64_t cycles, uint64_t retired, uint64_t interrupts,
                           uint64_t clint_writes, bool good_exit) {
  if (!enabled()) return;
  fprintf(output_, "{\"type\":\"finish\",\"valid\":%s,\"good_exit\":%s,"
          "\"cycles\":%" PRIu64 ",\"retired\":%" PRIu64
          ",\"interrupts\":%" PRIu64 ",\"clint_writes\":%" PRIu64 "}\n",
          valid_ && !pending_ ? "true" : "false", good_exit ? "true" : "false",
          cycles, retired, interrupts, clint_writes);
  if (fclose(output_) != 0) { perror("performance observer close"); exit(1); }
  output_ = nullptr;
}
