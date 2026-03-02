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

/* We use the POSIX regex functions to process regular expressions.
 * Type 'man regex' for more information about POSIX regex functions.
 */
#include <regex.h>

enum {
  TK_NOTYPE = 256, TK_EQ,

  /* TODO: Add more token types */
  TK_NUMBER,
  TK_NEG
};

static struct rule {
  const char *regex;
  int token_type;
} rules[] = {

  /* TODO: Add more rules.
   * Pay attention to the precedence level of different rules.
   */

  {" +", TK_NOTYPE},    // spaces
  {"\\+", '+'},         // plus
  {"==", TK_EQ},        // equal
  {"\\-", '-'},         // minus
  {"\\*", '*'},         // multiple
  {"\\/", '/'},         // divide
  {"[0-9]+u?", TK_NUMBER},// number
  {"\\(", '('},         // left parentheses
  {"\\)", ')'},         // right parentheses
};

#define NR_REGEX ARRLEN(rules)

static regex_t re[NR_REGEX] = {};

/* Rules are used for many times.
 * Therefore we compile them only once before any usage.
 */
void init_regex() {  //this is used for compiling the rules above!
  int i;
  char error_msg[128];
  int ret;

  for (i = 0; i < NR_REGEX; i ++) {
    ret = regcomp(&re[i], rules[i].regex, REG_EXTENDED);
    if (ret != 0) {
      regerror(ret, &re[i], error_msg, 128);
      panic("regex compilation failed: %s\n%s", error_msg, rules[i].regex);
    }
  }
}

typedef struct token {
  int type;
  char str[32];
} Token;

static Token tokens[32] __attribute__((used)) = {};
static int nr_token __attribute__((used))  = 0;

static bool make_token(char *e) {
  int position = 0;
  int i;
  regmatch_t pmatch;

  nr_token = 0;

  while (e[position] != '\0') {
    /* Try all rules one by one. */
    for (i = 0; i < NR_REGEX; i ++) {
      if (regexec(&re[i], e + position, 1, &pmatch, 0) == 0 && pmatch.rm_so == 0) {
        char *substr_start = e + position;
        int substr_len = pmatch.rm_eo;

        Log("match rules[%d] = \"%s\" at position %d with len %d: %.*s",
            i, rules[i].regex, position, substr_len, substr_len, substr_start);

        position += substr_len;

        /* TODO: Now a new token is recognized with rules[i]. Add codes
         * to record the token in the array `tokens'. For certain types
         * of tokens, some extra actions should be performed.
         */

        switch (rules[i].token_type) {
          case TK_NOTYPE:
            break;
          case TK_NUMBER:
            if(nr_token >= 32){
              printf("Error: there are too many tokens(max 32)\n");
              return false;
            }
            if(substr_len >=32){
              printf("Error: the number is too long at position %d\n", position);
              return false;
            }
            tokens[nr_token].type = rules[i].token_type;
            strncpy(tokens[nr_token].str, substr_start, substr_len);
            tokens[nr_token].str[substr_len] = '\0';
            nr_token ++;
            break;
          case '+':
          case '-':
          case '*':
          case '/':
          case '(':
          case ')':
          case TK_EQ:
            if(nr_token >= 32){
              printf("Error: there are too many tokens(max 32)\n");
              return false;  
            }
            tokens[nr_token].type = rules[i].token_type;
            nr_token++;
            break;

          
          default:
            panic("Error: undefine token type\n");
          }

        break;
      }
    }

    if (i == NR_REGEX) {
      printf("no match at position %d\n%s\n%*.s^\n", position, e, position, "");
      return false;
    }
  }

  return true;
}

static bool check_parentheses(int p, int q){
  if((tokens[p].type != '(') || (tokens[q].type != ')')){
    return false;
  }
  int level = 0;
  for(int i = p; i<=q; i++){
    if(tokens[i].type == '(')
      level++;
    else if(tokens[i].type == ')')
      level--;

    if(level == 0 && i < q){
      return false;
    }
  }
  if(level != 0){
    printf("Error: parentheses is not matched\n");
    return false;
  }
  else
    return true;
}

static int get_priorities(int type){
  switch(type){
    case TK_EQ:
      return 1;
    case '+':
    case '-':
      return 2;
    case '*':
    case '/':
      return 3;
    case TK_NEG:
      return 4;
    default:
      return 100;
    }
}

int find_main_op(int p, int q){
  int level = 0;
  int main_op_position = -1;
  int main_op_priority = 100;
  for (int i = p; i <= q; i++)
  {
    if(tokens[i].type == '('){
      level++;
    }
    else if(tokens[i].type == ')'){
      level--;
    }

    if((level == 0) && (tokens[i].type != TK_NOTYPE) && (tokens[i].type != TK_NUMBER) && (tokens[i].type != '(') && (tokens[i].type != ')')){
      if(get_priorities(tokens[i].type) <= main_op_priority){
        main_op_priority = get_priorities(tokens[i].type);
        main_op_position = i;
      }
    }
  }
  assert(main_op_position != -1);
  return main_op_position;
}

word_t eval(int p, int q) {
  if (p > q)
  {
    /* Bad expression */
    printf("Error: bad expression(start pointer is after end pointer)\n");
    assert(0);
  }
  else if (p == q) {
    /* Single token.
     * For now this token should be a number.
     * Return the value of the number.
     */
    word_t detected_number = 0;
    sscanf(tokens[p].str, "%u", &detected_number);
    return detected_number;
  }
  else if (check_parentheses(p, q) == true) {
    /* The expression is surrounded by a matched pair of parentheses.
     * If that is the case, just throw away the parentheses.
     */
    return eval(p + 1, q - 1);
  }
  else {
    int op = find_main_op(p,q);

    if(tokens[op].type == TK_NEG){
      return -eval(op + 1, q);
    }

    word_t val1 = eval(p, op - 1);
    word_t val2 = eval(op + 1, q);

    switch (tokens[op].type) {
      case '+': 
        return val1 + val2;
      case '-':
        return val1 - val2; /* ... */
      case '*': /* ... */
        return val1 * val2;
      case '/': 
        if(val2 == 0){
          printf("Error: Division by zero\n");
          assert(0);
        } /* ... */
        return val1 / val2;
      case TK_EQ:
        return val1 == val2;
      default:
        assert(0);
      }
  }
}


word_t expr(char *e, bool *success) {
  if (!make_token(e)) {
    *success = false;
    return 0;
  }

  /* TODO: Insert codes to evaluate the expression. */
  for (int i = 0; i < nr_token; i++){
    if(tokens[i].type == '-'){
      if(i == 0||(tokens[i-1].type != TK_NUMBER && tokens[i-1].type != ')')){
        tokens[i].type = TK_NEG;
      }
    }
  }

    *success = true;
  return eval(0, nr_token - 1);

}
