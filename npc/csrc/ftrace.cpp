#include "ftrace.h"

// TODO[C2-FTRACE-INCLUDE-0]: add headers needed by ELF parsing and symbol storage
//   这里就是要补 include 的位置。
//
//   你实现 ftrace_init() 时建议加：
//     #include <elf.h>       // Elf32_Ehdr / Elf32_Shdr / Elf32_Sym / ELF32_ST_TYPE
//     #include <string.h>    // memcmp
//     #include <stdlib.h>    // malloc/free if you choose C-style storage
//     #include <vector>      // std::vector, recommended
//     #include <string>      // std::string, recommended
//     #include <algorithm>   // std::sort
//
//   当前先不加这些头文件，因为骨架还没有实际使用它们。
#include <stdint.h>
#include <stdio.h>

static bool ftrace_enabled = false;

// TODO[C2-FTRACE-SYMBOL-0]: define file-scope function-symbol state here
//   这里就是要放函数符号表数据结构的位置。
//   注意：这些定义必须放在 ftrace_init() 外面，不能写成 ftrace_init() 的局部变量。
//
//   建议：
//     struct FuncSymbol {
//       uint32_t start;
//       uint32_t size;
//       std::string name;
//     };
//
//     static std::vector<FuncSymbol> func_symbols;
//     static int call_depth = 0;
//
//   文件级 static 的原因：
//     ftrace_init()    负责解析 ELF 并填充 func_symbols。
//     ftrace_update()  每条指令执行后查 func_symbols，并更新 call_depth。
//     ftrace_cleanup() 负责清空 func_symbols，并把 call_depth 复位。
//
//   如果写在 ftrace_init() 里面：
//     ftrace_update() 看不到符号表；
//     call_depth 每次初始化都会丢失；
//     cleanup 也无法释放/清理状态。
//
//   为什么放在这里：
//     ftrace_init() 负责填表，ftrace_update() 负责查表，二者都要访问。
//     这类软件状态不应该放到 RTL，也不应该从 CPU 执行循环里临时创建。

// TODO[C2-FTRACE-FIND-0]: add find_func(addr) helper here
//   这里就是查函数名 helper 的位置。
//   注意：这个 helper 也必须放在 ftrace_init() 外面，因为 ftrace_update() 要调用它。
//
//   目标函数：
//     static const FuncSymbol *find_func(uint32_t addr)
//
//   简单实现：
//     for (const auto &f : func_symbols) {
//       if (f.size == 0) {
//         if (addr == f.start) return &f;
//       } else if (addr >= f.start && addr < f.start + f.size) {
//         return &f;
//       }
//     }
//     return nullptr;
//
//   后续如果符号很多，可以用排序后的二分查找；当前阶段线性扫描足够。

void ftrace_init(bool enable_ftrace, const char *elf_path) {
  ftrace_enabled = enable_ftrace;

  // TODO[C2-FTRACE-INIT-0]: handle enable switch and missing ELF path here
  //   这里就是 ftrace 初始化入口检查的位置。
  //
  //   目标：
  //     if (!enable_ftrace) return;
  //
  //     if (elf_path == nullptr) {
  //       printf("ftrace: --ftrace requires --elf <program.elf>\n");
  //       ftrace_enabled = false;
  //       return;
  //     }
  //
  //   注意：
  //     ftrace 是调试功能。参数不完整时可以关闭 ftrace，不要影响普通 sim。
  (void)elf_path;

  // TODO[C2-FTRACE-ELF-0]: read whole ELF file into memory here
  //   这里就是打开 ELF、读取文件内容的位置。
  //
  //   建议写法：
  //     FILE *fp = fopen(elf_path, "rb");
  //     if (fp == nullptr) { perror("ftrace: fopen ELF"); ftrace_enabled = false; return; }
  //
  //     fseek(fp, 0, SEEK_END);
  //     long file_size = ftell(fp);
  //     fseek(fp, 0, SEEK_SET);
  //
  //     std::vector<uint8_t> elf(file_size);
  //     fread(elf.data(), 1, file_size, fp);
  //     fclose(fp);
  //
  //   边界：
  //     file_size <= 0 时关闭 ftrace。
  //     fread 返回值不等于 file_size 时关闭 ftrace。
  //
  //   用 std::vector<uint8_t> 的好处：
  //     自动管理内存，ftrace_init() 出错 return 时不会泄漏。

  // TODO[C2-FTRACE-ELF-1]: validate ELF header here
  //   这里就是检查 ELF header 的位置。
  //
  //   建议写法：
  //     Elf32_Ehdr *eh = reinterpret_cast<Elf32_Ehdr *>(elf.data());
  //
  //     检查：
  //       file_size >= sizeof(Elf32_Ehdr)
  //       memcmp(eh->e_ident, ELFMAG, SELFMAG) == 0
  //       eh->e_ident[EI_CLASS] == ELFCLASS32
  //       eh->e_machine == EM_RISCV
  //
  //     不满足就关闭 ftrace。这里不要 exit，ftrace 是调试功能，不应该影响普通 sim。

  // TODO[C2-FTRACE-ELF-2]: locate section header table here
  //   这里就是定位 section header table 的位置。
  //
  //   建议写法：
  //     Elf32_Shdr *shdrs = reinterpret_cast<Elf32_Shdr *>(elf.data() + eh->e_shoff);
  //
  //     需要先检查边界：
  //       eh->e_shoff + eh->e_shnum * sizeof(Elf32_Shdr) <= file_size
  //
  //   注意：
  //     所有 elf.data() + offset 之前都要先检查 offset/size 没越界。
  //     这是软件里最常见的 bug 来源。

  // TODO[C2-FTRACE-ELF-3]: find .symtab and its linked string table here
  //   这里就是找符号表和字符串表的位置。
  //
  //   建议写法：
  //     遍历 i = 0..eh->e_shnum-1:
  //       if (shdrs[i].sh_type == SHT_SYMTAB) {
  //         symtab = &shdrs[i];
  //         strtab = &shdrs[symtab->sh_link];
  //       }
  //
  //     注意：
  //       symtab->sh_link 指向符号名字符串表，不一定是 section 名字字符串表。
  //       不需要手动找 ".strtab" 名字，用 sh_link 更稳。
  //
  //   边界检查：
  //     symtab != nullptr
  //     symtab->sh_link < eh->e_shnum
  //     symtab->sh_offset + symtab->sh_size <= file_size
  //     strtab->sh_offset + strtab->sh_size <= file_size

  // TODO[C2-FTRACE-ELF-4]: iterate symbols and save STT_FUNC entries here
  //   这里就是遍历 ELF 符号表、保存函数符号的位置。
  //   注意：保存目标是文件顶部的 static func_symbols，不是在本函数里新建局部表。
  //
  //   建议写法：
  //     int sym_count = symtab->sh_size / sizeof(Elf32_Sym);
  //     Elf32_Sym *syms = reinterpret_cast<Elf32_Sym *>(elf.data() + symtab->sh_offset);
  //     const char *strs = reinterpret_cast<const char *>(elf.data() + strtab->sh_offset);
  //
  //     for each sym:
  //       uint8_t type = ELF32_ST_TYPE(sym.st_info);
  //       if (type != STT_FUNC) continue;
  //       if (sym.st_name == 0) continue;
  //       if (sym.st_value == 0) continue;
  //
  //       FuncSymbol f;
  //       f.start = sym.st_value;
  //       f.size  = sym.st_size;
  //       f.name  = strs + sym.st_name;
  //       func_symbols.push_back(f);
  //
  //   额外边界：
  //     sym.st_name < strtab->sh_size
  //     name 不能为空字符串
  //
  //   STT_FUNC 是函数符号。普通 object/data symbol 不应该进入 ftrace 函数表。

  // TODO[C2-FTRACE-ELF-5]: sort function symbols and print summary here
  //   这里就是符号表解析完成后的收尾位置。
  //
  //   建议写法：
  //     std::sort(func_symbols.begin(), func_symbols.end(),
  //               [](const FuncSymbol &a, const FuncSymbol &b) {
  //                 return a.start < b.start;
  //               });
  //
  //   你完成后建议打印：
  //     ftrace: loaded N function symbols from xxx.elf
  //
  //   高性能 CPU 关联：
  //     ftrace 属于 commit/retire 侧的调试观测能力。现在单周期可以在每条指令后判断，
  //     未来流水线或乱序 CPU 必须在 commit 阶段做，不能在 fetch/decode 阶段做。
}

void ftrace_cleanup() {
  // TODO[C2-FTRACE-ELF-1]: release ftrace symbol table here
  //   如果你按上面的建议使用：
  //     static std::vector<FuncSymbol> func_symbols;
  //
  //   那这里写：
  //     func_symbols.clear();
  //     call_depth = 0;
  //     ftrace_enabled = false;
  //
  //   如果你选择 malloc/new[] 保存符号表，必须在这里 free/delete[]。
  //
  //   软件侧注意点：
  //     cleanup 要允许重复调用，不要因为 vector 已经为空就出错。
}

void ftrace_update(uint32_t pc, uint32_t inst, uint32_t next_pc) {
  if (!ftrace_enabled) {
    return;
  }

  // TODO[C2-FTRACE-DECODE-0]: extract RISC-V fields here
  //   这里就是从 inst 里取 opcode/rd/rs1/imm 的位置。
  //
  //   目标代码：
  //     uint32_t opcode = inst & 0x7f;
  //     uint32_t rd     = (inst >> 7)  & 0x1f;
  //     uint32_t rs1    = (inst >> 15) & 0x1f;
  //     int32_t  imm_i  = (int32_t)inst >> 20;
  //
  //   这里不需要完整 decode，只需要判断 call/ret 所需字段。

  // TODO[C2-FTRACE-DECODE-1]: define call/return opcode constants here
  //   这里就是定义本地 opcode 常量的位置。
  //
  //   目标代码：
  //     constexpr uint32_t OPCODE_JAL  = 0x6f;
  //     constexpr uint32_t OPCODE_JALR = 0x67;
  //
  // TODO[C2-FTRACE-DECODE-2]: detect call instruction here
  //   这里就是判断 call 的位置。
  //
  //   目标代码：
  //     bool link_rd = (rd == 1 || rd == 5);  // x1 ra, x5 alternate link register
  //     bool is_call = false;
  //
  //     if (opcode == OPCODE_JAL && link_rd) {
  //       is_call = true;
  //     }
  //
  //     if (opcode == OPCODE_JALR && link_rd) {
  //       is_call = true;
  //     }
  //
  //   说明：
  //     RISC-V ABI 常用 x1 做 ra；x5 是 alternate link register。

  // TODO[C2-FTRACE-DECODE-3]: detect return instruction here
  //   这里就是判断 ret 的位置。
  //
  //     最常见 ret 是：
  //       jalr x0, x1, 0
  //
  //   建议字段判断：
  //       bool is_ret = (opcode == OPCODE_JALR) &&
  //                     (rd == 0) &&
  //                     (rs1 == 1) &&
  //                     (imm_i == 0);
  //
  //     也可以先用精确编码：
  //       bool is_ret = (inst == 0x00008067);
  //
  //     建议用字段判断，后面更容易扩展。
  //
  // TODO[C2-FTRACE-DECODE-4]: use next_pc as call/return target here
  //   这里就是确定 target 地址的位置。
  //
  //     对 call：
  //       当前单周期 NPC 里，ftrace_update(pc, inst, next_pc) 的 next_pc
  //       就是执行后的 PC，可以直接当作 call target。
  //
  //     对 ret：
  //       next_pc 是返回目标地址。
  //
  //     不建议在 ftrace.cpp 里重新解析 jal/jalr immediate，因为 RTL 已经算过目标。
  //     调试工具应该复用执行后的 next_pc，减少软件模型和 RTL 算法不一致的风险。
  //
  // TODO[C2-FTRACE-PRINT-0]: lookup function name and print trace here
  //   这里就是查函数名并打印 call/ret 的位置。
  //
  //     const FuncSymbol *target_func = find_func(next_pc);
  //     const FuncSymbol *cur_func    = find_func(pc);
  //
  //     call 时优先打印 target_func：
  //       0x80000010: call [foo@0x80000100]
  //
  //     ret 时优先打印 cur_func：
  //       0x80000120: ret  [foo]
  //
  //     如果找不到函数名，也要打印地址：
  //       0x80000010: call [0x80000100]
  //
  // TODO[C2-FTRACE-PRINT-1]: update and use call depth here
  //   这里就是维护调用深度缩进的位置。
  //
  //     用 call_depth 表示嵌套层数。
  //
  //     call:
  //       先按当前 call_depth 打印，再 call_depth++。
  //
  //     ret:
  //       先 if (call_depth > 0) call_depth--，再按新的深度打印。
  //
  // TODO[C2-FTRACE-DECODE-5]: ignore non-call/non-return instructions here
  //   这里就是过滤普通指令的位置。
  //
  //     if (!is_call && !is_ret) return;
  //
  //   高性能 CPU 关联：
  //     ftrace 的输入应该来自“已提交指令”的 pc/inst/next_pc。
  //     乱序 CPU 里分支预测路径上的 call/ret 不能进入 ftrace，否则会记录被 squash 的指令。
  (void)pc;
  (void)inst;
  (void)next_pc;
}
