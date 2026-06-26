#include "cpu.h"
#include "mem.h"
#include "sdb.h"
#include "trace.h"
#include "watchpoint.h"

#include <cstring>
#include <iostream>

int main(int argc, char **argv) {

  bool enable_nvboard = false;
  bool enable_trace = false;
  bool enable_itrace = false;
  const char *img_path = nullptr;
  // ============================================================
  // Parse command line arguments
  //
  // Supported examples:
  //   ./top_sim
  //   ./top_sim program.bin
  //   ./top_sim --trace program.bin
  //   ./top_nvboard --nvboard program.bin
  //   ./top_nvboard --trace --nvboard program.bin
  //
  // Any argument that is not an option is treated as image path.
  // ============================================================
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--trace") == 0) {
      enable_trace = true;
    } else if (strcmp(argv[i], "--itrace") == 0) {
      enable_itrace = true;
    } else if (strcmp(argv[i], "--nvboard") == 0) {
      enable_nvboard = true;
    } else {
      img_path = argv[i];
    }
  }

  cpu_init(argc, argv, enable_nvboard, enable_trace);

  init_wp_pool();

  trace_init(enable_itrace);
  if (img_path != nullptr) {
    load_bin(img_path);
    std::cout << "NPC: load image" << img_path << std::endl;
  } else {
    std::cout << "NPC: No image, MEM is empty" << std::endl;
  }

  cpu_reset(10);

  sdb_mainloop();

  trace_cleanup();
  cpu_cleanup();

  return 0;
}