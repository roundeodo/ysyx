#include "cpu.h"
#include "ftrace.h"
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
  bool enable_mtrace = false;
  bool enable_ftrace = false;
  const char *img_path = nullptr;
  const char *elf_path = nullptr;
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
    } else if (strcmp(argv[i], "--mtrace") == 0) {
      enable_mtrace = true;
    } else if (strcmp(argv[i], "--ftrace") == 0) {
      enable_ftrace = true;
    } else if (strcmp(argv[i], "--elf") == 0) {
      // TODO[C2-FTRACE-ARGS-0]: validate --elf argument here
      //   这里就是 ftrace 命令行参数要补的位置。
      //
      //   当前先只取下一个 argv 作为 ELF 路径。
      //   你后续要补：
      //     1. 如果 i + 1 >= argc，打印 usage 并退出。
      //     2. 如果用户开了 --ftrace 但没给 --elf，提示 ftrace 需要 ELF。
      //     3. IMG 仍然是 bin，ELF 只给 ftrace 解析符号表，不直接 load 到 pmem。
      if (i + 1 < argc) {
        elf_path = argv[++i];
      }
    } else if (strcmp(argv[i], "--nvboard") == 0) {
      enable_nvboard = true;
    } else {
      img_path = argv[i];
    }
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

  sdb_mainloop();

  trace_cleanup();
  ftrace_cleanup();
  cpu_cleanup();

  return 0;
}
