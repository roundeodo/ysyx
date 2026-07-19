#include "cpu.h"
#include "difftest.h"
#include "ftrace.h"
#include "mem.h"
#include "sdb.h"
#include "trace.h"
#include "watchpoint.h"

#include <cstring>
#include <stdint.h>
#include <iostream>
#include <string>

int main(int argc, char **argv) {

  bool enable_nvboard = false;
  bool enable_trace = false;
  bool enable_itrace = false;
  bool enable_mtrace = false;
  bool enable_ftrace = false;
  bool enable_difftest = false;
  bool batch_mode = false;

  const char *img_path = nullptr;
  const char *elf_path = nullptr;
  const char *diff_so_file = nullptr;
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
    } else if (strcmp(argv[i], "--batch") == 0) {
      batch_mode = true;
    } else if (strcmp(argv[i], "--itrace") == 0) {
      enable_itrace = true;
    } else if (strcmp(argv[i], "--mtrace") == 0) {
      enable_mtrace = true;
    } else if (strcmp(argv[i], "--ftrace") == 0) {
      enable_ftrace = true;
    } else if (strcmp(argv[i], "--diff") == 0) {
      if (i + 1 >= argc || strncmp(argv[i + 1], "--", 2) == 0) {
        std::cout << "Usage: --diff <ref-so>" << std::endl;
        return 1;
      }
      enable_difftest = true;
      diff_so_file = argv[++i];
    } else if (strcmp(argv[i], "--elf") == 0) {
      if (i + 1 >= argc || strncmp(argv[i + 1], "--", 2) == 0) {
        std::cout << "Usage: --elf <program.elf>" << std::endl;
        return 1;
      }
      elf_path = argv[++i];
    } else if (strcmp(argv[i], "--nvboard") == 0) {
      enable_nvboard = true;
    } else if (argv[i][0] == '+') {
      // Verilator plusargs are consumed by the SystemVerilog test model.
      continue;
    } else {
      img_path = argv[i];
    }
  }

  if (enable_ftrace && elf_path == nullptr) {
    std::cout << "ftrace requires --elf <program.elf>" << std::endl;
    return 1;
  }

  cpu_init(argc, argv, enable_nvboard, enable_trace);

  init_wp_pool();

  trace_init(enable_itrace, enable_mtrace);
  ftrace_init(enable_ftrace, elf_path);
  if (img_path != nullptr) {
    load_bin(img_path);
    std::cout << "NPC: load image" << img_path << std::endl;
  } else {
    std::cout << "NPC: No image, MEM is empty" << std::endl;
  }

  cpu_reset(10);

  difftest_init(enable_difftest, diff_so_file, get_img_size());

  if (batch_mode) {
    cpu_exec(UINT64_MAX);
  } else {
    sdb_mainloop();
  }

  trace_cleanup();
  ftrace_cleanup();
  difftest_cleanup();
  cpu_cleanup();
  return 0;
}
