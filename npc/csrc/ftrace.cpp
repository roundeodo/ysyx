#include "ftrace.h"

#include <stdint.h>
#include <stdio.h>

static bool ftrace_enabled = false;

void ftrace_init(bool enable_ftrace, const char *elf_path) {
  ftrace_enabled = enable_ftrace;

  // TODO[C2-FTRACE-ELF-0]: parse ELF symbol table here
  //   这里就是 ftrace 初始化要改的位置。
  //
  //   目标：
  //     1. 如果 !enable_ftrace，直接 return。
  //     2. 如果 elf_path == nullptr，打印提示并关闭 ftrace。
  //     3. 打开 ELF 文件，读取 ELF header、section header。
  //     4. 找到 .symtab 和 .strtab。
  //     5. 遍历符号表，只保存 STT_FUNC 类型符号：
  //          name
  //          start address
  //          size
  //
  //   推荐文件：
  //     <elf.h>
  //
  //   高性能 CPU 关联：
  //     ftrace 属于 commit/retire 侧的调试观测能力。现在单周期可以在每条指令后判断，
  //     未来流水线或乱序 CPU 必须在 commit 阶段做，不能在 fetch/decode 阶段做。
  (void)elf_path;
}

void ftrace_cleanup() {
  // TODO[C2-FTRACE-ELF-1]: release ftrace symbol table here
  //   如果你在 ftrace_init() 里用 vector/string，可以不需要手动释放。
  //   如果用 malloc/new[] 保存符号表，就在这里释放。
}

void ftrace_update(uint32_t pc, uint32_t inst, uint32_t next_pc) {
  if (!ftrace_enabled) {
    return;
  }

  // TODO[C2-FTRACE-DECODE-0]: detect call/return instructions here
  //   这里就是 ftrace 运行时判断要改的位置。
  //
  //   RISC-V 常见规则：
  //     call:
  //       jal  rd, target     且 rd == x1 或 rd == x5
  //       jalr rd, rs1, imm   且 rd == x1 或 rd == x5
  //
  //     return:
  //       jalr x0, x1, 0
  //       常见编码是 0x00008067
  //
  //   target:
  //     对 jal/jalr，当前单周期 NPC 可以直接使用 next_pc。
  //
  //   输出建议：
  //     0x80000010: call [foo@0x80000100]
  //     0x80000120: ret  [foo]
  //
  //   高性能 CPU 关联：
  //     ftrace 的输入应该来自“已提交指令”的 pc/inst/next_pc。
  //     乱序 CPU 里分支预测路径上的 call/ret 不能进入 ftrace，否则会记录被 squash 的指令。
  (void)pc;
  (void)inst;
  (void)next_pc;
}

