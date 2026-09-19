#include "perf_observer.h"
#include <cstdlib>

// Two accepted timer reads can overlap while the older load waits in WB.
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  PerfObserver observer;
  observer.open(argv[1], 700000000, 1000000);
  observer.sample({100, 20, 1, 0x1000, 0x2000, 0});
  observer.sample({102, 21, 2, 0x1000, 0x3000, 0});
  observer.commit(103, 0x9999, 0x00002003, true);  // Unrelated retirement.
  observer.commit(104, 0x1000, 0x00002003, true);
  const int mode = std::atoi(argv[2]);
  if (mode != 2)
    observer.commit(108, 0x1000, 0x00002003, mode != 1);
  observer.finish(110, 24, 0, 0, true);
}
