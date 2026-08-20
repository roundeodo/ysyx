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
#include <cpu/cpu.h>
#include <readline/readline.h>
#include <readline/history.h>
#include "sdb.h"
#include <memory/vaddr.h>
#include "watchpoint.h"

static int is_batch_mode = false;

void init_regex();
void init_wp_pool();

/* We use the `readline' library to provide more flexibility to read from stdin. */
static char* rl_gets() {
  static char *line_read = NULL;

  if (line_read) {
    free(line_read);
    line_read = NULL;
  }

  line_read = readline("(nemu) ");

  if (line_read && *line_read) {
    add_history(line_read);
  }

  return line_read;
}

static int cmd_c(char *args) {
  cpu_exec(-1);
  return 0;
}


static int cmd_q(char *args) {
  set_nemu_state(NEMU_QUIT, cpu.pc, 0);
  return -1;
}

static int cmd_help(char *args);

static int cmd_si(char *args){
  uint64_t n = 0;
  if (args == NULL)
  {
    n = 1;
  }
  else{
    int ret = sscanf(args, "%lu", &n);
    if(ret != 1){
      printf("invalid argument '%s'. Usage: si [N]\n", args);
      return 0;
    }
  }
  cpu_exec(n);
  return 0;
}

static int cmd_info(char *args){
  if(args == NULL){
    printf("Error: lack of instruction\n");
  }
  if(*args == 'r'){
    isa_reg_display();
  }
  else if(*args == 'w'){
    watchpoint_list();
  }
  return 0;
}

static int cmd_x(char *args){
  char *arg_n = strtok(args, " ");
  if(arg_n == NULL){
    printf("error: missing the size of target area\n");
    return 0;
  }
  int n;
  if (sscanf(arg_n, "%d", &n)!= 1){
    printf("Error: Invalid number N\n");
    return 0;
  }
  char *arg_expr = args + strlen(arg_n) + 1;
  while(*arg_expr == ' ')
    arg_expr++;
  if (*arg_expr == '\0')
  {
    printf("Error: Missing the initial address expression\n");
    return 0;
  }
  bool success = false;
  word_t transferred_address = expr(arg_expr, &success);
  if(!success){
    printf("Error: invalid expression '%s'.\n", arg_expr);
    return 0;
  }
  for (int i = 0; i < n; i++)
  {
    vaddr_t addr = transferred_address + i*4;
    word_t data = vaddr_read(addr, 4);
    printf(FMT_WORD ": " FMT_WORD "\n", addr, data);
  }
  return 0;
}

static int cmd_p(char *args){
  if(args == NULL){
    printf("Error: missing expression\n");
    return 0;
  }
  bool success;
  word_t result = expr(args, &success);
  if(success){
    printf("%llu (" FMT_WORD ")\n", (unsigned long long)result, result);
  }
  else{
    printf("Error: invalid expression '%s'.\n", args);
  }
  return 0;
}

static int cmd_w(char *args){
  if(args == NULL){
    printf("Error: missing expression\n");
    return 0;
  }
  bool success;
  word_t result = expr(args, &success);
  if(success){
    WP *user_watchpoint = new_wp();
    strncpy(user_watchpoint->user_expression, args, sizeof(user_watchpoint->user_expression) - 1);
    user_watchpoint->user_expression[sizeof(user_watchpoint->user_expression) - 1] = '\0';
    user_watchpoint->old_value = result;
    printf("Set watchpoint #%d: %s, initial value = %llu (" FMT_WORD ")\n",
           user_watchpoint->NO, user_watchpoint->user_expression,
           (unsigned long long)result, result);
  }
  else{
    printf("Error: bad expression\n");
  }
  return 0;
}

static int cmd_d(char *args){
  if(args == NULL){
    printf("Error: missing watchpoint number\n");
    return 0;
  }
  int watchpoint_number;
  if(sscanf(args, "%u", &watchpoint_number) != 1){
    printf("Error: invalid watchpoint number\n");
    return 0;
  }
  if(watchpoint_number < 0 || watchpoint_number > 31){
    printf("Error: watchpoint number %d is out of range(0-31)\n", watchpoint_number);
    return 0;
  }
  if(delete_wp_by_number(watchpoint_number)){
    printf("Watchpoint %d deleted\n", watchpoint_number);
  }
  else{
    printf("Error: watchpoint %d is not set, can't be deleted\n", watchpoint_number);
  }
  return 0;
}

static struct
{
  const char *name;
  const char *description;
  int (*handler) (char *);
} cmd_table[] = {
    {"help", "Display information about all supported commands", cmd_help},
    {"c"   , "Continue the execution of the program"           , cmd_c},
    {"q"   , "Exit NEMU"                                       , cmd_q},

    /* TODO: Add more commands */
    {"si"       , "execute N instsructions and pause"                                                  , cmd_si},
    {"info"     , "show the information of sub command"                                                , cmd_info},
    {"x"        , "calculate the value of EXPR for the initial memory address and output N 4-byte data", cmd_x},
    {"p"        , "calculate the value of EXPR"                                                        , cmd_p},
    {"w"        , "set the watch point at EXPR and pause the program when the value of EXPR is changed", cmd_w},
    {"d"        , "delete NO.N watch point"                                                            , cmd_d}
  };

#define NR_CMD ARRLEN(cmd_table)

static int cmd_help(char *args) {
  /* extract the first argument */
  char *arg = strtok(NULL, " ");
  int i;

  if (arg == NULL) {
    /* no argument given */
    for (i = 0; i < NR_CMD; i ++) {
      printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
    }
  }
  else {
    for (i = 0; i < NR_CMD; i ++) {
      if (strcmp(arg, cmd_table[i].name) == 0) {
        printf("%s - %s\n", cmd_table[i].name, cmd_table[i].description);
        return 0;
      }
    }
    printf("Unknown command '%s'\n", arg);
  }
  return 0;
}




void sdb_set_batch_mode() {
  is_batch_mode = true;
}

void sdb_mainloop() {
  if (is_batch_mode) {
    cmd_c(NULL);
    return;
  }

  for (char *str; (str = rl_gets()) != NULL; ) {
    char *str_end = str + strlen(str);

    /* extract the first token as the command */
    char *cmd = strtok(str, " ");  //strtok is used to find the first non-" " string  and the first *delaim will be replaced by '\0'
    if (cmd == NULL) { continue; }

    /* treat the remaining string as the arguments,
     * which may need further parsing
     */
    char *args = cmd + strlen(cmd) + 1; //cmd is now pointing at the start point of slice  strlen(cmd) is the length of the slice
    // +1 means args is pointing at the start of next slice
    if (args >= str_end) {
      args = NULL;
    }

#ifdef CONFIG_DEVICE
    extern void sdl_clear_event_queue();
    sdl_clear_event_queue();
#endif

    int i;
    for (i = 0; i < NR_CMD; i ++) {
      if (strcmp(cmd, cmd_table[i].name) == 0) {
        if (cmd_table[i].handler(args) < 0) { return; }
        break;
      }
    }

    if (i == NR_CMD) { printf("Unknown command '%s'\n", cmd); }
  }
}

void init_sdb() {
  /* Compile the regular expressions. */
  init_regex();

  /* Initialize the watchpoint pool. */
  init_wp_pool();
}
