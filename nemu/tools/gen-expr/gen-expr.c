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

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <assert.h>
#include <string.h>

// this should be enough
static int generation_depth = 0;
static char buf[65536] = {};
static char code_buf[65536 + 128] = {}; // a little larger than `buf`
static char *code_format =
"#include <stdio.h>\n"
"int main() { "
"  unsigned result = %s; "
"  printf(\"%%u\", result); "
"  return 0; "
"}";

int choose(int n){
  return (rand() % n);
}

void gen_num(){
  char number[32];
  if(choose(2) == 0){
    sprintf(number, "%uu", rand()%100);
  }
  else{
    sprintf(number, "0x%xu", rand() % 100);
  }
  strcat(buf, number);
}

void gen(char symbol){
  char parentheses[2] = {symbol, '\0'};
  if (symbol == '(')
  {
    strcat(buf, parentheses);
  }
  else if(symbol == ')'){
    strcat(buf, parentheses);
  }
}

void gen_rand_spaces(int n){
  int space_number = choose(n);
  for (int i = 0; i < space_number; i ++){
    strcat(buf, " ");
  }
}

void gen_rand_op(){
  char *op_list[] = {"+ ", "- ", "* ", "/ ", "&& ", "!= ", "== "};
  int op_index = choose(7);
  strcat(buf, op_list[op_index]);
}


void gen_rand_expr(){
  if(strlen(buf)>500 || generation_depth >2){
    if(choose(5) == 0)
      strcat(buf, "- ");
    gen_num();
    return;
  }

  generation_depth++;

  switch (choose(3))
  {
  case 0:
    gen_rand_spaces(10);
    if(choose(5) == 0)
      strcat(buf, "- ");
    gen_num();
    gen_rand_spaces(10);
    break;
  case 1:
    if(choose(5) == 0)
      strcat(buf, "- ");
    gen('(');
    gen_rand_expr();
    gen(')');
    break;

  default:
    gen_rand_expr();
    gen_rand_spaces(10);
    gen_rand_op();
    gen_rand_spaces(10);
    gen_rand_expr();
    break;
  }
  generation_depth--;
}

int main(int argc, char *argv[]) {
  int seed = time(0);
  srand(seed);
  int loop = 1;
  if (argc > 1) {
    sscanf(argv[1], "%d", &loop);
  }
  int i;
  for (i = 0; i < loop; i ++) {
    buf[0] = '\0';
    generation_depth = 0;
    gen_rand_expr();

    sprintf(code_buf, code_format, buf);

    FILE *fp = fopen("/tmp/.code.c", "w");
    assert(fp != NULL);
    fputs(code_buf, fp);
    fclose(fp);

    int ret = system("gcc /tmp/.code.c -o /tmp/.expr");
    if (ret != 0) continue;

    ret = system("/tmp/.expr > /dev/null 2>&1");
    if(ret != 0){
      continue;
    }

    fp = popen("/tmp/.expr", "r");
    assert(fp != NULL);

    int result;
    ret = fscanf(fp, "%u", &result);
    pclose(fp);

    printf("%u %s\n", result, buf);
  }
  return 0;
}
