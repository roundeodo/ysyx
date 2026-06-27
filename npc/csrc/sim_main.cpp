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
      //   参数设计：
      //     --ftrace              打开 ftrace
      //     --elf program.elf     指定带符号表的 ELF 文件
      //     最后一个非 option 参数仍然是要加载到 pmem 的 bin 镜像。
      //
      //   为什么需要同时有 bin 和 ELF：
      //     bin 是真正加载到 NPC memory 执行的内容。
      //     ELF 用来读取 .symtab/.strtab，给 ftrace 查函数名。
      //
      //   你后续要补：
      //     1. 如果 i + 1 >= argc：
      //          printf("Usage: --elf <program.elf>\n");
      //          return 1;
      //
      //     2. 如果 argv[i + 1] 以 "--" 开头，说明用户没给路径：
      //          printf("Usage: --elf <program.elf>\n");
      //          return 1;
      //
      //     3. 循环结束后检查：
      //          if (enable_ftrace && elf_path == nullptr) {
      //            printf("ftrace requires --elf <program.elf>\n");
      //            return 1;
      //          }
      //
      //     4. 不要把 ELF 当成 img_path。
      //        当前代码用 ++i 跳过 ELF 路径，这个方向是对的。
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
