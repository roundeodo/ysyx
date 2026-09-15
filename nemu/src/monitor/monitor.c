/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <isa.h>
#include <cpu/branchsim-trace.h>
#include <cpu/cachesim-trace.h>
#include <memory/paddr.h>
#include <elf.h>
#include <stdlib.h>
#include <string.h>

#ifdef CONFIG_FTRACE

typedef struct 
{
  /* data */
  char name[64];
  uint32_t start; // start address
  uint32_t end;   // end address
} FuncSymbol;
static FuncSymbol *ftable = NULL;
static int func_count = 0;
int ftrace_depth = 0;

#endif




void init_rand();
void init_log(const char *log_file);
void init_mem();
void init_difftest(char *ref_so_file, long img_size, int port);
void init_device();
void init_sdb();
void init_disasm();

static void welcome() {
  Log("Trace: %s", MUXDEF(CONFIG_TRACE, ANSI_FMT("ON", ANSI_FG_GREEN), ANSI_FMT("OFF", ANSI_FG_RED)));
  IFDEF(CONFIG_TRACE, Log("If trace is enabled, a log file will be generated "
        "to record the trace. This may lead to a large log file. "
        "If it is not necessary, you can disable it in menuconfig"));
  Log("Build time: %s, %s", __TIME__, __DATE__);
  printf("Welcome to %s-NEMU!\n", ANSI_FMT(str(__GUEST_ISA__), ANSI_FG_YELLOW ANSI_BG_RED));
  printf("For help, type \"help\"\n");
}

#ifndef CONFIG_TARGET_AM
#include <getopt.h>

void sdb_set_batch_mode();

static char *log_file = NULL;
static char *diff_so_file = NULL;
static char *img_file = NULL;
static char *cachesim_trace_file = NULL;
static char *cachesim_data_trace_file = NULL;
static char *branchsim_trace_file = NULL;
static int difftest_port = 1234;

#ifdef CONFIG_FTRACE

static char *elf_file = NULL;

#endif

static long load_img() {
  if (img_file == NULL) {
    Log("No image is given. Use the default build-in image.");
    return 4096; // built-in image size
  }

  FILE *fp = fopen(img_file, "rb");
  Assert(fp, "Can not open '%s'", img_file);

  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);

  Log("The image is %s, size = %ld", img_file, size);

  fseek(fp, 0, SEEK_SET);
  int ret = fread(guest_to_host(RESET_VECTOR), size, 1, fp);
  assert(ret == 1);

  fclose(fp);
  return size;
}

#ifdef CONFIG_FTRACE
static void read_elf_data(void *ptr, size_t size, size_t nmemb, FILE *fp){
  size_t ret = fread(ptr, size, nmemb, fp);
  assert(ret == nmemb);
}

void init_ftrace(const char *elf_file){
  if(elf_file == NULL){
    printf("Error: elf file unavailable\n");
    return;
  }
  // read ELF file
  FILE *fp = fopen(elf_file, "rb");
  Assert(fp, "Error: elf file '%s' cannot be opened", elf_file);

  // read ELF header
  Elf32_Ehdr ehdr;
  read_elf_data(&ehdr, sizeof(Elf32_Ehdr), 1, fp);
  Assert(ehdr.e_ident[EI_MAG0] == ELFMAG0 && ehdr.e_ident[EI_MAG1] == ELFMAG1 && ehdr.e_ident[EI_MAG2] == ELFMAG2 && ehdr.e_ident[EI_MAG3] == ELFMAG3, "Error:'%s' is not an ELF file", elf_file);
  Assert(ehdr.e_ident[EI_CLASS] == ELFCLASS32, "Error: Only ELF32 is supported now");
  Assert(ehdr.e_shentsize == sizeof(Elf32_Shdr), "Error: section header size illegal");
  // read section header table
  Elf32_Shdr *shdrs = malloc(ehdr.e_shentsize * ehdr.e_shnum);
  assert(shdrs);
  fseek(fp, ehdr.e_shoff, SEEK_SET); // seek_set is the start of the file, use it as base addr here
  read_elf_data(shdrs, ehdr.e_shentsize, ehdr.e_shnum, fp);

  // read shstrtab
  Elf32_Shdr *shstr_shdr = &shdrs[ehdr.e_shstrndx];
  char *shstrtab = malloc(shstr_shdr->sh_size);
  assert(shstrtab);
  fseek(fp, shstr_shdr->sh_offset, SEEK_SET);
  read_elf_data(shstrtab, shstr_shdr->sh_size, 1, fp);

  // find the .symtab section header
  // section name = shstrtab + shdrs[i].name    name -- offset
  Elf32_Shdr *symtab_shdr = NULL;
  for (int i = 0; i < ehdr.e_shnum; i++){
    const char *sec_name = shstrtab + shdrs[i].sh_name; // sh_name is the offset of section name in str table
    if(strcmp(sec_name,".symtab") == 0){
      symtab_shdr = &shdrs[i];
      break;
    }
  }
  
  if(symtab_shdr == NULL){
    printf("Error: No .symtab found in ELF file '%s'\n", elf_file);
    free(shstrtab);
    free(shdrs);
    fclose(fp);
    return;
  }
  
  //check if symbol table entry is legal
  Assert(symtab_shdr->sh_entsize == sizeof(Elf32_Sym), "Error: symbol entry size illegal");
  
  // find str table corresponding to symbol table
  Elf32_Shdr *strtab_shdr = &shdrs[symtab_shdr->sh_link]; // sh_link point at strtab
  Elf32_Sym *syms = malloc(symtab_shdr->sh_size);
  assert(syms);
  fseek(fp, symtab_shdr->sh_offset, SEEK_SET);
  read_elf_data(syms, symtab_shdr->sh_size, 1, fp); // read the entire symbol table

  // read .strtab
  char *strtab = malloc(strtab_shdr->sh_size);
  assert(strtab);
  fseek(fp, strtab_shdr->sh_offset, SEEK_SET);
  read_elf_data(strtab, strtab_shdr->sh_size, 1, fp);
  int nr_sym = symtab_shdr->sh_size / symtab_shdr->sh_entsize;
  ftable = malloc(sizeof(FuncSymbol) * nr_sym);
  assert(ftable);
  func_count = 0;

  // traversal symbol for selecting
  for (int i = 0; i < nr_sym;i++){
    Elf32_Sym *sym = &syms[i]; // one symbol extracted from symbol table
    if(ELF32_ST_TYPE(sym->st_info) != STT_FUNC){
      continue;
    }
    if(sym->st_name == 0){ // jump if there is no name
      continue;
    }
    const char *name = strtab + sym->st_name;

    snprintf(ftable[func_count].name, sizeof(ftable[func_count].name), "%s", name); // to the address of name for extracting a string and save it into the first address
    ftable[func_count].start = sym->st_value;
    ftable[func_count].end = sym->st_value + sym->st_size;
    func_count++;
  }

  // check extraction result
  printf("ftrace: load %d function symbols from %s\n", func_count, elf_file);
  for (int i = 0; i < func_count; i++){
    printf("ftrace symbol: start = 0x%08x, end = 0x%08x, name = %s\n", ftable[i].start, ftable[i].end, ftable[i].name);
  }

  // temporary memory free
  free(strtab);
  free(syms);
  free(shstrtab);
  free(shdrs);
  fclose(fp);
}

static const char *find_func_by_addr(vaddr_t addr){
  for (int i = 0; i < func_count; i++){
    uint32_t start = ftable[i].start;
    uint32_t end = ftable[i].end;

    if(start == end){
      if(addr == start){
        return ftable[i].name;
      }
    }
    else{
      if(addr >= start && addr < end){
        return ftable[i].name;
      }
    }
  }
  return "???";
}

// print indent based on the depth
static void print_ftrace_indent(void){
  for (int i = 0; i < ftrace_depth; i++){
    printf(" ");
  }
}

// record function call
void ftrace_call(vaddr_t pc, vaddr_t target){
  const char *func_name = find_func_by_addr(target);
  printf("0x%08x: ", pc);
  print_ftrace_indent();
  printf("call [%s@0x%08x]\n", func_name, target);

  ftrace_depth++;
}

void ftrace_ret(vaddr_t pc){
  if(ftrace_depth > 0){
    ftrace_depth--;
  }
  const char *func_name = find_func_by_addr(pc);
  printf("0x%08x: ", pc);
  print_ftrace_indent();
  printf("ret [%s]\n", func_name);
}
#endif


static int parse_args(int argc, char *argv[]) {
  const struct option table[] = {
    {"batch"    , no_argument      , NULL, 'b'},
    {"log"      , required_argument, NULL, 'l'},
    {"diff"     , required_argument, NULL, 'd'},
    {"port"     , required_argument, NULL, 'p'},
    {"cachesim-trace", required_argument, NULL, 256},
    {"cachesim-data-trace", required_argument, NULL, 257},
    {"branchsim-trace", required_argument, NULL, 258},
    #ifdef CONFIG_FTRACE
    {"elf"      , required_argument, NULL, 'e'},
    #endif
    {"help"     , no_argument      , NULL, 'h'},
    {0          , 0                , NULL,  0 },
  };
  int o;
  while ( (o = getopt_long(argc, argv, "-bhl:d:p:e:", table, NULL)) != -1) {
    switch (o) {
      case 'b': sdb_set_batch_mode(); break;
      case 'p': sscanf(optarg, "%d", &difftest_port); break;
      case 'l': log_file = optarg; break;
      case 'd': diff_so_file = optarg; break;
      case 256: cachesim_trace_file = optarg; break;
      case 257: cachesim_data_trace_file = optarg; break;
      case 258: branchsim_trace_file = optarg; break;
      #ifdef CONFIG_FTRACE
      case 'e':
        elf_file = optarg;
        break;
      #endif
      case 1:
        img_file = optarg;
        return 0;
      default:
        printf("Usage: %s [OPTION...] IMAGE [args]\n\n", argv[0]);
        printf("\t-b,--batch              run with batch mode\n");
        printf("\t-l,--log=FILE           output log to FILE\n");
        printf("\t-d,--diff=REF_SO        run DiffTest with reference REF_SO\n");
        printf("\t-p,--port=PORT          run DiffTest with port PORT\n");
        printf("\t--cachesim-trace=FILE   write compact program-counter trace\n");
        printf("\t--cachesim-data-trace=FILE write compact architectural data trace\n");
        printf("\t--branchsim-trace=FILE  write compact retired control-flow trace\n");
        #ifdef CONFIG_FTRACE
        printf("\t-e,--elf=FILE           load ELF file for ftrace\n");
        #endif
        printf("\n");
        exit(0);
    }
  }
  return 0;
}

void init_monitor(int argc, char *argv[]) {
  /* Perform some global initialization. */

  /* Parse arguments. */
  parse_args(argc, argv);

  /* Set random seed. */
  init_rand();

  /* Open the log file. */
  init_log(log_file);

  init_cachesim_trace(cachesim_trace_file);
  init_cachesim_data_trace(cachesim_data_trace_file);
  init_branchsim_trace(branchsim_trace_file);
  
  #ifdef CONFIG_FTRACE
  /* Parse ELF file and load function symbols for ftrace */
  init_ftrace(elf_file);
  #endif

  /* Initialize memory. */
  init_mem();

  /* Initialize devices. */
  IFDEF(CONFIG_DEVICE, init_device());

  /* Perform ISA dependent initialization. */
  init_isa();

  /* Load the image to memory. This will overwrite the built-in image. */
  long img_size = load_img();

  /* Initialize differential testing. */
  init_difftest(diff_so_file, img_size, difftest_port);

  /* Initialize the simple debugger. */
  init_sdb();

#if defined(CONFIG_ITRACE) || defined(CONFIG_IQUEUE) || defined(CONFIG_IRINGBUF)
    init_disasm();
#endif

  /* Display welcome message. */
  welcome();
}
#else // CONFIG_TARGET_AM
static long load_img() {
  extern char bin_start, bin_end;
  size_t size = &bin_end - &bin_start;
  Log("img size = %ld", size);
  memcpy(guest_to_host(RESET_VECTOR), &bin_start, size);
  return size;
}

void am_init_monitor() {
  init_rand();
  init_mem();
  init_isa();
  load_img();
  IFDEF(CONFIG_DEVICE, init_device());
  welcome();
}
#endif
