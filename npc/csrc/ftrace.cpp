#include "ftrace.h"

#include <elf.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <algorithm>
#include <string>
#include <vector>

struct FuncSymbol {
  uint32_t start;
  uint32_t size;
  std::string name;
};

static bool ftrace_enabled = false;
static std::vector<FuncSymbol> func_symbols;
static int call_depth = 0;

static void disable_ftrace() {
  ftrace_enabled = false;
  call_depth = 0;
  func_symbols.clear();
}

static bool in_file_range(size_t offset, size_t size, size_t file_size) {
  return offset <= file_size && size <= file_size - offset;
}

static const FuncSymbol *find_func(uint32_t addr) {
  for (size_t i = 0; i < func_symbols.size(); i++) {
    const FuncSymbol &f = func_symbols[i];
    if (addr < f.start) {
      continue;
    }

    uint64_t end = 0;
    if (f.size != 0) {
      end = static_cast<uint64_t>(f.start) + f.size;
    } else if (i + 1 < func_symbols.size()) {
      end = func_symbols[i + 1].start;
    } else {
      end = static_cast<uint64_t>(f.start) + 1;
    }

    if (addr < end) {
      return &f;
    }
  }

  return nullptr;
}

static const char *func_name_or_addr(const FuncSymbol *func, uint32_t addr,
                                     char *buf, size_t size) {
  if (func != nullptr) {
    return func->name.c_str();
  }

  snprintf(buf, size, "0x%08x", addr);
  return buf;
}

void ftrace_init(bool enable_ftrace, const char *elf_path) {
  ftrace_enabled = enable_ftrace;
  call_depth = 0;
  func_symbols.clear();

  if (!enable_ftrace) {
    return;
  }

  if (elf_path == nullptr) {
    printf("ftrace: --ftrace requires --elf <program.elf>\n");
    disable_ftrace();
    return;
  }

  FILE *fp = fopen(elf_path, "rb");
  if (fp == nullptr) {
    perror("ftrace: fopen ELF");
    disable_ftrace();
    return;
  }

  if (fseek(fp, 0, SEEK_END) != 0) {
    perror("ftrace: fseek ELF end");
    fclose(fp);
    disable_ftrace();
    return;
  }

  long file_size_long = ftell(fp);
  if (file_size_long <= 0) {
    printf("ftrace: invalid ELF size: %ld\n", file_size_long);
    fclose(fp);
    disable_ftrace();
    return;
  }

  if (fseek(fp, 0, SEEK_SET) != 0) {
    perror("ftrace: fseek ELF start");
    fclose(fp);
    disable_ftrace();
    return;
  }

  size_t file_size = static_cast<size_t>(file_size_long);
  std::vector<uint8_t> elf(file_size);

  if (fread(elf.data(), 1, file_size, fp) != file_size) {
    printf("ftrace: failed to read complete ELF file\n");
    fclose(fp);
    disable_ftrace();
    return;
  }

  fclose(fp);

  if (file_size < sizeof(Elf32_Ehdr)) {
    printf("ftrace: ELF file is too small\n");
    disable_ftrace();
    return;
  }

  const Elf32_Ehdr *eh = reinterpret_cast<const Elf32_Ehdr *>(elf.data());
  if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 ||
      eh->e_ident[EI_CLASS] != ELFCLASS32 || eh->e_machine != EM_RISCV) {
    printf("ftrace: unsupported ELF file, need RV32 ELF\n");
    disable_ftrace();
    return;
  }

  if (eh->e_shentsize != sizeof(Elf32_Shdr)) {
    printf("ftrace: unexpected section header entry size\n");
    disable_ftrace();
    return;
  }

  size_t shdr_bytes = static_cast<size_t>(eh->e_shnum) * sizeof(Elf32_Shdr);
  if (!in_file_range(eh->e_shoff, shdr_bytes, file_size)) {
    printf("ftrace: section header table is out of ELF file range\n");
    disable_ftrace();
    return;
  }

  const Elf32_Shdr *shdrs =
      reinterpret_cast<const Elf32_Shdr *>(elf.data() + eh->e_shoff);

  const Elf32_Shdr *symtab = nullptr;
  const Elf32_Shdr *strtab = nullptr;

  for (uint16_t i = 0; i < eh->e_shnum; i++) {
    if (shdrs[i].sh_type != SHT_SYMTAB) {
      continue;
    }

    if (shdrs[i].sh_link >= eh->e_shnum) {
      printf("ftrace: invalid symtab string-table link\n");
      disable_ftrace();
      return;
    }

    symtab = &shdrs[i];
    strtab = &shdrs[symtab->sh_link];
    break;
  }

  if (symtab == nullptr || strtab == nullptr) {
    printf("ftrace: no .symtab found in ELF, rebuild with symbols\n");
    disable_ftrace();
    return;
  }

  if (symtab->sh_entsize != 0 && symtab->sh_entsize != sizeof(Elf32_Sym)) {
    printf("ftrace: unexpected symbol table entry size\n");
    disable_ftrace();
    return;
  }

  if (!in_file_range(symtab->sh_offset, symtab->sh_size, file_size) ||
      !in_file_range(strtab->sh_offset, strtab->sh_size, file_size)) {
    printf("ftrace: symtab or strtab is out of ELF file range\n");
    disable_ftrace();
    return;
  }

  int sym_count = symtab->sh_size / sizeof(Elf32_Sym);
  const Elf32_Sym *syms =
      reinterpret_cast<const Elf32_Sym *>(elf.data() + symtab->sh_offset);
  const char *strs =
      reinterpret_cast<const char *>(elf.data() + strtab->sh_offset);

  for (int i = 0; i < sym_count; i++) {
    const Elf32_Sym &sym = syms[i];

    if (ELF32_ST_TYPE(sym.st_info) != STT_FUNC) {
      continue;
    }

    if (sym.st_name == 0 || sym.st_name >= strtab->sh_size) {
      continue;
    }

    if (sym.st_value == 0) {
      continue;
    }

    const char *name = strs + sym.st_name;
    if (name[0] == '\0') {
      continue;
    }

    FuncSymbol f;
    f.start = sym.st_value;
    f.size = sym.st_size;
    f.name = name;
    func_symbols.push_back(f);
  }

  std::sort(func_symbols.begin(), func_symbols.end(),
            [](const FuncSymbol &a, const FuncSymbol &b) {
              return a.start < b.start;
            });

  printf("ftrace: loaded %zu function symbols from %s\n", func_symbols.size(),
         elf_path);
}

void ftrace_cleanup() {
  disable_ftrace();
}

void ftrace_update(uint32_t pc, uint32_t inst, uint32_t next_pc) {
  if (!ftrace_enabled) {
    return;
  }

  uint32_t opcode = inst & 0x7f;
  uint32_t rd = (inst >> 7) & 0x1f;
  uint32_t rs1 = (inst >> 15) & 0x1f;
  int32_t imm_i = static_cast<int32_t>(inst) >> 20;

  constexpr uint32_t OPCODE_JAL = 0x6f;
  constexpr uint32_t OPCODE_JALR = 0x67;

  bool link_rd = rd == 1 || rd == 5;
  bool is_call = (opcode == OPCODE_JAL && link_rd) ||
                 (opcode == OPCODE_JALR && link_rd);
  bool is_ret = opcode == OPCODE_JALR && rd == 0 && (rs1 == 1 || rs1 == 5) &&
                imm_i == 0;

  if (!is_call && !is_ret) {
    return;
  }

  uint32_t target_pc = next_pc;
  const FuncSymbol *target_func = find_func(target_pc);
  const FuncSymbol *cur_func = find_func(pc);

  char target_buf[32];
  char cur_buf[32];
  const char *target_name = func_name_or_addr(target_func, target_pc, target_buf,
                                             sizeof(target_buf));
  const char *cur_name = func_name_or_addr(cur_func, pc, cur_buf, sizeof(cur_buf));

  if (is_ret && call_depth > 0) {
    call_depth--;
  }

  printf("ftrace: 0x%08x: ", pc);
  for (int i = 0; i < call_depth; i++) {
    printf("  ");
  }

  if (is_call) {
    printf("call [%s@0x%08x]\n", target_name, target_pc);
    call_depth++;
  } else {
    printf("ret  [%s] -> 0x%08x\n", cur_name, target_pc);
  }
}
