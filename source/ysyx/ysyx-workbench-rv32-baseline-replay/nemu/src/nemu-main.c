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

#include <common.h>

void init_monitor(int, char *[]);
void am_init_monitor();
void engine_start();
int is_exit_status_bad();

word_t expr(char *e, bool *success);

int main(int argc, char *argv[]) {
  /* Initialize the monitor. */
#ifdef CONFIG_TARGET_AM
  am_init_monitor();
#else
  init_monitor(argc, argv);
#endif

  /* Start engine. */
  engine_start();
  // FILE *fp = fopen("tools/gen-expr/input", "r");
  // if(fp == NULL){
  //   perror("can't open test input file");
  //   return 1;
  // }
  // unsigned int expected_result;
  // char expression[65536];
  // int test_count = 0;
  // while(fscanf(fp,"%u %[^\n]",&expected_result, expression)!=EOF){
  //   bool success;
  //   word_t test_result = expr(expression, &success);
  //   if(!success){
  //     printf("Error at test #%d\n", test_count);
  //     assert(0);
  //   }

  //   if(test_result != expected_result){
  //     printf("Error: mismatch at test #%d\n", test_count);
  //     printf("expression %s\n", expression);
  //     printf("expected: %u calculated: %u\n", expected_result, test_result);
  //     assert(0);
  //   }
  //   test_count++;
  //   if(test_count % 499 == 0){
  //     printf("all test have been passed\n");
  //   }
  // }
  // fclose(fp);
  nemu_state.state = NEMU_QUIT;

  return is_exit_status_bad();
}
