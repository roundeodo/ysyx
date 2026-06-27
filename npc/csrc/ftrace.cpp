#include "ftrace.h"

#include <stdint.h>
#include <stdio.h>

static bool ftrace_enabled = false;

void ftrace_init(bool enable_ftrace, const char *elf_path) {
  ftrace_enabled = enable_ftrace;

  // TODO[C2-FTRACE-ELF-0]: parse ELF symbol table here
  //   这里就是 ftrace 初始化要改的位置。
  //
  //   第一步：补头文件
  //     #include <elf.h>
  //     #include <string.h>
  //     #include <stdlib.h>
  //     #include <vector>
  //     #include <string>
  //     #include <algorithm>
  //
  //   第二步：定义函数符号结构。建议放在文件顶部 static 区域：
  //     struct FuncSymbol {
  //       uint32_t start;
  //       uint32_t size;
  //       std::string name;
  //     };
  //
  //     static std::vector<FuncSymbol> func_symbols;
  //     static int call_depth = 0;
  //
  //   第三步：处理开关和参数
  //     if (!enable_ftrace) return;
  //
  //     if (elf_path == nullptr) {
  //       printf("ftrace: --ftrace requires --elf <program.elf>\n");
  //       ftrace_enabled = false;
  //       return;
  //     }
  //
  //   第四步：读完整 ELF 文件到内存
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
  //   第五步：检查 ELF header
  //     Elf32_Ehdr *eh = reinterpret_cast<Elf32_Ehdr *>(elf.data());
  //
  //     检查：
  //       file_size >= sizeof(Elf32_Ehdr)
  //       memcmp(eh->e_ident, ELFMAG, SELFMAG) == 0
  //       eh->e_ident[EI_CLASS] == ELFCLASS32
  //       eh->e_machine == EM_RISCV
  //
  //     不满足就关闭 ftrace。这里不要 exit，ftrace 是调试功能，不应该影响普通 sim。
  //
  //   第六步：找到 section header table
  //     Elf32_Shdr *shdrs = reinterpret_cast<Elf32_Shdr *>(elf.data() + eh->e_shoff);
  //
  //     需要先检查边界：
  //       eh->e_shoff + eh->e_shnum * sizeof(Elf32_Shdr) <= file_size
  //
  //   第七步：找到 .symtab 和它关联的 string table
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
  //   第八步：遍历符号表，只保存函数符号
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
  //   第九步：排序，方便按地址查函数
  //     std::sort(func_symbols.begin(), func_symbols.end(),
  //               [](const FuncSymbol &a, const FuncSymbol &b) {
  //                 return a.start < b.start;
  //               });
  //
  //   第十步：实现一个查找函数，建议放在文件顶部 static 函数区：
  //     static const FuncSymbol *find_func(uint32_t addr)
  //
  //     简单写法：
  //       遍历 func_symbols，判断：
  //         if (addr >= f.start && addr < f.start + f.size) return &f;
  //
  //     注意 st_size 可能为 0。size 为 0 时可以只允许 addr == f.start。
  //
  //   你完成后建议打印：
  //     ftrace: loaded N function symbols from xxx.elf
  //
  //   高性能 CPU 关联：
  //     ftrace 属于 commit/retire 侧的调试观测能力。现在单周期可以在每条指令后判断，
  //     未来流水线或乱序 CPU 必须在 commit 阶段做，不能在 fetch/decode 阶段做。
  (void)elf_path;
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

  // TODO[C2-FTRACE-DECODE-0]: detect call/return instructions here
  //   这里就是 ftrace 运行时判断要改的位置。
  //
  //   第一步：提取 RISC-V 基本字段
  //     uint32_t opcode = inst & 0x7f;
  //     uint32_t rd     = (inst >> 7)  & 0x1f;
  //     uint32_t rs1    = (inst >> 15) & 0x1f;
  //     int32_t  imm_i  = (int32_t)inst >> 20;
  //
  //   第二步：定义 opcode 常量
  //     constexpr uint32_t OPCODE_JAL  = 0x6f;
  //     constexpr uint32_t OPCODE_JALR = 0x67;
  //
  //   第三步：判断 call
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
  //   第四步：判断 ret
  //     最常见 ret 是：
  //       jalr x0, x1, 0
  //
  //     可以写成字段判断：
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
  //   第五步：target 地址怎么来
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
  //   第六步：查函数名
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
  //   第七步：缩进
  //     用 call_depth 表示嵌套层数。
  //
  //     call:
  //       先按当前 call_depth 打印，再 call_depth++。
  //
  //     ret:
  //       先 if (call_depth > 0) call_depth--，再按新的深度打印。
  //
  //   第八步：过滤非控制流指令
  //     if (!is_call && !is_ret) return;
  //
  //   高性能 CPU 关联：
  //     ftrace 的输入应该来自“已提交指令”的 pc/inst/next_pc。
  //     乱序 CPU 里分支预测路径上的 call/ret 不能进入 ftrace，否则会记录被 squash 的指令。
  (void)pc;
  (void)inst;
  (void)next_pc;
}
