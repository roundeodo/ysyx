#include "ftrace.h"

// TODO[C2-FTRACE-INCLUDE-0]: add headers needed by ELF parsing and symbol storage here.
// #include <elf.h>       // Elf32_Ehdr / Elf32_Shdr / Elf32_Sym / ELF32_ST_TYPE
// #include <string.h>    // memcmp
// #include <vector>      // std::vector, recommended
// #include <string>      // std::string, recommended
// #include <algorithm>   // std::sort
#include <stdint.h>
#include <stdio.h>

static bool ftrace_enabled = false;

// TODO[C2-FTRACE-SYMBOL-0]: define file-scope function-symbol state here.
// struct FuncSymbol {
//   uint32_t start;
//   uint32_t size;
//   std::string name;
// };
// static std::vector<FuncSymbol> func_symbols;
// static int call_depth = 0;
// Note: this must stay outside ftrace_init(), because init fills it, update reads it,
// and cleanup clears it. This is commit-side debug state, not RTL architectural state.

// TODO[C2-FTRACE-FIND-0]: add find_func(addr) helper here.
// static const FuncSymbol *find_func(uint32_t addr) {
//   for (const auto &f : func_symbols) {
//     if (f.size == 0) {
//       if (addr == f.start) return &f;
//     } else if (addr >= f.start && addr < f.start + f.size) {
//       return &f;
//     }
//   }
//   return nullptr;
// }
// Current stage can use linear scan. Later, after sorting, this can become binary search.

void ftrace_init(bool enable_ftrace, const char *elf_path) {
  ftrace_enabled = enable_ftrace;

  // TODO[C2-FTRACE-INIT-0]: handle enable switch and missing ELF path here.
  // if (!enable_ftrace) return;
  // if (elf_path == nullptr) {
  //   printf("ftrace: --ftrace requires --elf <program.elf>\n");
  //   ftrace_enabled = false;
  //   return;
  // }
  // ftrace is debug-only. Bad ftrace args should disable ftrace, not kill normal sim.

  // TODO[C2-FTRACE-ELF-0]: read whole ELF file into memory here.
  // FILE *fp = fopen(elf_path, "rb");
  // if (fp == nullptr) { perror("ftrace: fopen ELF"); ftrace_enabled = false; return; }
  // fseek(fp, 0, SEEK_END);
  // long file_size = ftell(fp);
  // fseek(fp, 0, SEEK_SET);
  // if (file_size <= 0) { fclose(fp); ftrace_enabled = false; return; }
  // std::vector<uint8_t> elf(file_size);
  // if (fread(elf.data(), 1, file_size, fp) != (size_t)file_size) {
  //   fclose(fp);
  //   ftrace_enabled = false;
  //   return;
  // }
  // fclose(fp);

  // TODO[C2-FTRACE-ELF-1]: validate ELF header here.
  // if ((size_t)file_size < sizeof(Elf32_Ehdr)) { ftrace_enabled = false; return; }
  // Elf32_Ehdr *eh = reinterpret_cast<Elf32_Ehdr *>(elf.data());
  // if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 ||
  //     eh->e_ident[EI_CLASS] != ELFCLASS32 ||
  //     eh->e_machine != EM_RISCV) {
  //   ftrace_enabled = false;
  //   return;
  // }

  // TODO[C2-FTRACE-ELF-2]: locate section header table here.
  // size_t shdr_bytes = (size_t)eh->e_shnum * sizeof(Elf32_Shdr);
  // if ((size_t)eh->e_shoff + shdr_bytes > (size_t)file_size) {
  //   ftrace_enabled = false;
  //   return;
  // }
  // Elf32_Shdr *shdrs = reinterpret_cast<Elf32_Shdr *>(elf.data() + eh->e_shoff);
  // Always check offset/size before using elf.data() + offset.

  // TODO[C2-FTRACE-ELF-3]: find .symtab and its linked string table here.
  // const Elf32_Shdr *symtab = nullptr;
  // const Elf32_Shdr *strtab = nullptr;
  // for (uint16_t i = 0; i < eh->e_shnum; i++) {
  //   if (shdrs[i].sh_type == SHT_SYMTAB) {
  //     symtab = &shdrs[i];
  //     if (symtab->sh_link < eh->e_shnum) strtab = &shdrs[symtab->sh_link];
  //     break;
  //   }
  // }
  // if (symtab == nullptr || strtab == nullptr) { ftrace_enabled = false; return; }
  // if ((size_t)symtab->sh_offset + symtab->sh_size > (size_t)file_size ||
  //     (size_t)strtab->sh_offset + strtab->sh_size > (size_t)file_size) {
  //   ftrace_enabled = false;
  //   return;
  // }
  // symtab->sh_link points to the symbol-name string table. Do not search by ".strtab" name.

  // TODO[C2-FTRACE-ELF-4]: iterate symbols and save STT_FUNC entries here.
  // int sym_count = symtab->sh_size / sizeof(Elf32_Sym);
  // Elf32_Sym *syms = reinterpret_cast<Elf32_Sym *>(elf.data() + symtab->sh_offset);
  // const char *strs = reinterpret_cast<const char *>(elf.data() + strtab->sh_offset);
  // for (int i = 0; i < sym_count; i++) {
  //   const Elf32_Sym &sym = syms[i];
  //   if (ELF32_ST_TYPE(sym.st_info) != STT_FUNC) continue;
  //   if (sym.st_name == 0 || sym.st_name >= strtab->sh_size) continue;
  //   if (sym.st_value == 0) continue;
  //   FuncSymbol f;
  //   f.start = sym.st_value;
  //   f.size  = sym.st_size;
  //   f.name  = strs + sym.st_name;
  //   if (!f.name.empty()) func_symbols.push_back(f);
  // }

  // TODO[C2-FTRACE-ELF-5]: sort function symbols and print summary here.
  // std::sort(func_symbols.begin(), func_symbols.end(),
  //           [](const FuncSymbol &a, const FuncSymbol &b) {
  //             return a.start < b.start;
  //           });
  // printf("ftrace: loaded %zu function symbols from %s\n", func_symbols.size(), elf_path);
  // High-performance CPU note: ftrace must consume committed pc/inst/next_pc.
  // In a future OoO CPU, fetch/decode-path call/ret must not enter ftrace before commit.
  (void)elf_path;
}

void ftrace_cleanup() {
  // TODO[C2-FTRACE-CLEANUP-0]: release ftrace symbol table here.
  // func_symbols.clear();
  // call_depth = 0;
  // ftrace_enabled = false;
  // cleanup should be repeatable. If you choose malloc/new[], free/delete[] here.
}

void ftrace_update(uint32_t pc, uint32_t inst, uint32_t next_pc) {
  if (!ftrace_enabled) {
    return;
  }

  // TODO[C2-FTRACE-DECODE-0]: extract only the fields needed by call/ret detection here.
  // uint32_t opcode = inst & 0x7f;
  // uint32_t rd     = (inst >> 7)  & 0x1f;
  // uint32_t rs1    = (inst >> 15) & 0x1f;
  // int32_t imm_i   = (int32_t)inst >> 20;

  // TODO[C2-FTRACE-DECODE-1]: define local opcode constants here.
  // constexpr uint32_t OPCODE_JAL  = 0x6f;
  // constexpr uint32_t OPCODE_JALR = 0x67;

  // TODO[C2-FTRACE-DECODE-2]: detect call instruction here.
  // bool link_rd = (rd == 1 || rd == 5);  // x1 ra, x5 alternate link register
  // bool is_call = false;
  // if (opcode == OPCODE_JAL && link_rd) is_call = true;
  // if (opcode == OPCODE_JALR && link_rd) is_call = true;

  // TODO[C2-FTRACE-DECODE-3]: detect return instruction here.
  // bool is_ret = (opcode == OPCODE_JALR) &&
  //               (rd == 0) &&
  //               (rs1 == 1) &&
  //               (imm_i == 0);

  // TODO[C2-FTRACE-DECODE-4]: ignore non-call/non-return instructions here.
  // if (!is_call && !is_ret) return;
  // High-performance CPU note: only committed call/ret can enter ftrace.
  // Future speculative fetch/decode call/ret must be ignored until commit/retire.

  // TODO[C2-FTRACE-DECODE-5]: use next_pc as call/return target here.
  // uint32_t target_pc = next_pc;
  // Do not recalculate jal/jalr target here. RTL already produced the committed next_pc.

  // TODO[C2-FTRACE-PRINT-0]: lookup function names here.
  // const FuncSymbol *target_func = find_func(target_pc);
  // const FuncSymbol *cur_func    = find_func(pc);
  // call should prefer target_func; ret should prefer cur_func.

  // TODO[C2-FTRACE-PRINT-1]: update call depth and print trace here.
  // if (is_ret && call_depth > 0) call_depth--;
  // for (int i = 0; i < call_depth; i++) printf("  ");
  // if (is_call) {
  //   printf("0x%08x: call [%s@0x%08x]\n", pc, target_func ? target_func->name.c_str() : "?", target_pc);
  //   call_depth++;
  // } else {
  //   printf("0x%08x: ret  [%s]\n", pc, cur_func ? cur_func->name.c_str() : "?");
  // }
  (void)pc;
  (void)inst;
  (void)next_pc;
}
