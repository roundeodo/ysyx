#include "ftrace.h"

// TODO[C2-FTRACE-INCLUDE-0]: add these includes here, not inside any function.
// #include <elf.h>       // Elf32_Ehdr / Elf32_Shdr / Elf32_Sym / ELF32_ST_TYPE
// #include <string.h>    // memcmp
// #include <vector>      // std::vector, recommended
// #include <string>      // std::string, recommended
// #include <algorithm>   // std::sort
#include <stdint.h>
#include <stdio.h>

static bool ftrace_enabled = false;

// TODO[C2-FTRACE-SYMBOL-0]: define the function-symbol record type here, above ftrace_init().
// struct FuncSymbol {
//   uint32_t start;
//   uint32_t size;
//   std::string name;
// };

// TODO[C2-FTRACE-SYMBOL-1]: define file-scope ftrace state here, above ftrace_init().
// static std::vector<FuncSymbol> func_symbols;
// static int call_depth = 0;
// Note: this must stay outside ftrace_init(), because init fills it, update reads it,
// and cleanup clears it. This is commit-side debug state, not RTL architectural state.

// TODO[C2-FTRACE-UTIL-0]: add a small helper to disable ftrace on init errors here, above ftrace_init().
// static void disable_ftrace() {
//   ftrace_enabled = false;
//   call_depth = 0;
//   func_symbols.clear();
// }
// This keeps ftrace_init() readable. It is software debug state cleanup, not CPU behavior.

// TODO[C2-FTRACE-FIND-0]: add find_func(addr) helper here, above ftrace_init().
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

  // TODO[C2-FTRACE-INIT-0]: return immediately when ftrace is disabled here.
  // if (!enable_ftrace) return;

  // TODO[C2-FTRACE-INIT-1]: reject missing ELF path here.
  // if (elf_path == nullptr) {
  //   printf("ftrace: --ftrace requires --elf <program.elf>\n");
  //   disable_ftrace();
  //   return;
  // }
  // ftrace is debug-only. Bad ftrace args should disable ftrace, not kill normal sim.

  // TODO[C2-FTRACE-ELF-0]: open ELF file here.
  // FILE *fp = fopen(elf_path, "rb");
  // if (fp == nullptr) {
  //   perror("ftrace: fopen ELF");
  //   disable_ftrace();
  //   return;
  // }

  // TODO[C2-FTRACE-ELF-1]: get ELF file size here.
  // fseek(fp, 0, SEEK_END);
  // long file_size = ftell(fp);
  // fseek(fp, 0, SEEK_SET);
  // if (file_size <= 0) {
  //   fclose(fp);
  //   disable_ftrace();
  //   return;
  // }

  // TODO[C2-FTRACE-ELF-2]: allocate an ELF byte buffer here.
  // std::vector<uint8_t> elf(file_size);

  // TODO[C2-FTRACE-ELF-3]: read ELF bytes into the buffer here.
  // if (fread(elf.data(), 1, file_size, fp) != (size_t)file_size) {
  //   fclose(fp);
  //   disable_ftrace();
  //   return;
  // }

  // TODO[C2-FTRACE-ELF-4]: close the ELF file after the full read here.
  // fclose(fp);

  // TODO[C2-FTRACE-EHDR-0]: check that the file is large enough for Elf32_Ehdr here.
  // if ((size_t)file_size < sizeof(Elf32_Ehdr)) {
  //   disable_ftrace();
  //   return;
  // }

  // TODO[C2-FTRACE-EHDR-1]: create the ELF header pointer here.
  // Elf32_Ehdr *eh = reinterpret_cast<Elf32_Ehdr *>(elf.data());

  // TODO[C2-FTRACE-EHDR-2]: validate ELF magic/class/machine here.
  // if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 ||
  //     eh->e_ident[EI_CLASS] != ELFCLASS32 ||
  //     eh->e_machine != EM_RISCV) {
  //   disable_ftrace();
  //   return;
  // }

  // TODO[C2-FTRACE-SHDR-0]: calculate section header table byte size here.
  // size_t shdr_bytes = (size_t)eh->e_shnum * sizeof(Elf32_Shdr);

  // TODO[C2-FTRACE-SHDR-1]: check section header table bounds here.
  // if ((size_t)eh->e_shoff + shdr_bytes > (size_t)file_size) {
  //   disable_ftrace();
  //   return;
  // }

  // TODO[C2-FTRACE-SHDR-2]: create the section header table pointer here.
  // Elf32_Shdr *shdrs = reinterpret_cast<Elf32_Shdr *>(elf.data() + eh->e_shoff);
  // Always check offset/size before using elf.data() + offset.

  // TODO[C2-FTRACE-SYMTAB-0]: declare symtab/strtab pointers here.
  // const Elf32_Shdr *symtab = nullptr;
  // const Elf32_Shdr *strtab = nullptr;

  // TODO[C2-FTRACE-SYMTAB-1]: scan section headers to find SHT_SYMTAB here.
  // for (uint16_t i = 0; i < eh->e_shnum; i++) {
  //   if (shdrs[i].sh_type == SHT_SYMTAB) {
  //     symtab = &shdrs[i];
  //     if (symtab->sh_link < eh->e_shnum) strtab = &shdrs[symtab->sh_link];
  //     break;
  //   }
  // }

  // TODO[C2-FTRACE-SYMTAB-2]: reject missing symtab/strtab here.
  // if (symtab == nullptr || strtab == nullptr) {
  //   disable_ftrace();
  //   return;
  // }

  // TODO[C2-FTRACE-SYMTAB-3]: check symtab/strtab file bounds here.
  // if ((size_t)symtab->sh_offset + symtab->sh_size > (size_t)file_size ||
  //     (size_t)strtab->sh_offset + strtab->sh_size > (size_t)file_size) {
  //   disable_ftrace();
  //   return;
  // }
  // symtab->sh_link points to the symbol-name string table. Do not search by ".strtab" name.

  // TODO[C2-FTRACE-FUNC-0]: derive symbol count and table pointers here.
  // int sym_count = symtab->sh_size / sizeof(Elf32_Sym);
  // Elf32_Sym *syms = reinterpret_cast<Elf32_Sym *>(elf.data() + symtab->sh_offset);
  // const char *strs = reinterpret_cast<const char *>(elf.data() + strtab->sh_offset);

  // TODO[C2-FTRACE-FUNC-1]: iterate ELF symbols here.
  // for (int i = 0; i < sym_count; i++) {
  //   const Elf32_Sym &sym = syms[i];

  // TODO[C2-FTRACE-FUNC-2]: filter non-function or invalid symbols inside the loop here.
  //   if (ELF32_ST_TYPE(sym.st_info) != STT_FUNC) continue;
  //   if (sym.st_name == 0 || sym.st_name >= strtab->sh_size) continue;
  //   if (sym.st_value == 0) continue;

  // TODO[C2-FTRACE-FUNC-3]: push one valid function symbol inside the loop here.
  //   FuncSymbol f;
  //   f.start = sym.st_value;
  //   f.size  = sym.st_size;
  //   f.name  = strs + sym.st_name;
  //   if (!f.name.empty()) func_symbols.push_back(f);
  // }

  // TODO[C2-FTRACE-FINISH-0]: sort function symbols here.
  // std::sort(func_symbols.begin(), func_symbols.end(),
  //           [](const FuncSymbol &a, const FuncSymbol &b) {
  //             return a.start < b.start;
  //           });

  // TODO[C2-FTRACE-FINISH-1]: print ftrace symbol-load summary here.
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
