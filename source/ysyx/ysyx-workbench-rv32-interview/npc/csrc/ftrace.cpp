#include "ftrace.h"

#include <elf.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <algorithm>
#include <string>
#include <vector>

struct FuncSymbol {
  npc_word_t start;
  uint64_t size;
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

static const FuncSymbol *find_func(npc_word_t addr) {
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

static const char *func_name_or_addr(const FuncSymbol *func, npc_word_t addr,
                                     char *buf, size_t size) {
  if (func != nullptr) {
    return func->name.c_str();
  }

  snprintf(buf, size, "0x%0*llx", NPC_WORD_HEX_DIGITS,
           static_cast<unsigned long long>(addr));
  return buf;
}

template <typename Ehdr, typename Shdr, typename Sym>
static bool load_function_symbols(const std::vector<uint8_t> &elf) {
  const size_t file_size = elf.size();
  const Ehdr *eh = reinterpret_cast<const Ehdr *>(elf.data());

  if (eh->e_machine != EM_RISCV || eh->e_shentsize != sizeof(Shdr)) {
    printf("ftrace: unsupported RISC-V ELF section-header layout\n");
    return false;
  }

  const size_t shdr_bytes = static_cast<size_t>(eh->e_shnum) * sizeof(Shdr);
  if (!in_file_range(static_cast<size_t>(eh->e_shoff), shdr_bytes, file_size)) {
    printf("ftrace: section header table is out of ELF file range\n");
    return false;
  }

  const Shdr *shdrs = reinterpret_cast<const Shdr *>(
      elf.data() + static_cast<size_t>(eh->e_shoff));
  const Shdr *symtab = nullptr;
  const Shdr *strtab = nullptr;

  for (uint16_t i = 0; i < eh->e_shnum; i++) {
    if (shdrs[i].sh_type != SHT_SYMTAB) {
      continue;
    }
    if (shdrs[i].sh_link >= eh->e_shnum) {
      printf("ftrace: invalid symtab string-table link\n");
      return false;
    }
    symtab = &shdrs[i];
    strtab = &shdrs[symtab->sh_link];
    break;
  }

  if (symtab == nullptr || strtab == nullptr) {
    printf("ftrace: no .symtab found in ELF, rebuild with symbols\n");
    return false;
  }
  if (symtab->sh_entsize != 0 && symtab->sh_entsize != sizeof(Sym)) {
    printf("ftrace: unexpected symbol table entry size\n");
    return false;
  }
  if (!in_file_range(static_cast<size_t>(symtab->sh_offset),
                     static_cast<size_t>(symtab->sh_size), file_size) ||
      !in_file_range(static_cast<size_t>(strtab->sh_offset),
                     static_cast<size_t>(strtab->sh_size), file_size)) {
    printf("ftrace: symtab or strtab is out of ELF file range\n");
    return false;
  }

  const size_t symbol_count = static_cast<size_t>(symtab->sh_size) / sizeof(Sym);
  const Sym *symbols = reinterpret_cast<const Sym *>(
      elf.data() + static_cast<size_t>(symtab->sh_offset));
  const char *strings = reinterpret_cast<const char *>(
      elf.data() + static_cast<size_t>(strtab->sh_offset));

  for (size_t i = 0; i < symbol_count; i++) {
    const Sym &symbol = symbols[i];
    if (ELF64_ST_TYPE(symbol.st_info) != STT_FUNC || symbol.st_name == 0 ||
        symbol.st_name >= strtab->sh_size || symbol.st_value == 0) {
      continue;
    }

    const char *name = strings + symbol.st_name;
    if (name[0] == '\0') {
      continue;
    }

    func_symbols.push_back({static_cast<npc_word_t>(symbol.st_value),
                            static_cast<uint64_t>(symbol.st_size), name});
  }
  return true;
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

  if (file_size < EI_NIDENT) {
    printf("ftrace: ELF file is too small\n");
    disable_ftrace();
    return;
  }

  const unsigned char *ident = elf.data();
  if (memcmp(ident, ELFMAG, SELFMAG) != 0) {
    printf("ftrace: input file is not ELF\n");
    disable_ftrace();
    return;
  }

  bool symbols_loaded = false;
  if (ident[EI_CLASS] == ELFCLASS32 && file_size >= sizeof(Elf32_Ehdr)) {
    symbols_loaded = load_function_symbols<Elf32_Ehdr, Elf32_Shdr, Elf32_Sym>(elf);
  } else if (ident[EI_CLASS] == ELFCLASS64 && file_size >= sizeof(Elf64_Ehdr)) {
    symbols_loaded = load_function_symbols<Elf64_Ehdr, Elf64_Shdr, Elf64_Sym>(elf);
  } else {
    printf("ftrace: unsupported ELF class\n");
  }

  if (!symbols_loaded) {
    disable_ftrace();
    return;
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

void ftrace_update(npc_word_t pc, uint32_t inst, npc_word_t next_pc) {
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

  npc_word_t target_pc = next_pc;
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

  printf("ftrace: 0x%0*llx: ", NPC_WORD_HEX_DIGITS,
         static_cast<unsigned long long>(pc));
  for (int i = 0; i < call_depth; i++) {
    printf("  ");
  }

  if (is_call) {
    printf("call [%s@0x%0*llx]\n", target_name, NPC_WORD_HEX_DIGITS,
           static_cast<unsigned long long>(target_pc));
    call_depth++;
  } else {
    printf("ret  [%s] -> 0x%0*llx\n", cur_name, NPC_WORD_HEX_DIGITS,
           static_cast<unsigned long long>(target_pc));
  }
}
