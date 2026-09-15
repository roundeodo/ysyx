#include "expr.h"
#include "cpu.h"
#include "mem.h"

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>
#include <vector>

enum TokenType {
  TK_NUM,
  TK_REG,

  TK_EQ,
  TK_NEQ,
  TK_AND,
  TK_OR,

  TK_PLUS,
  TK_MINUS,
  TK_MUL,
  TK_DIV,

  TK_NOT,

  TK_LPAREN,
  TK_RPAREN
};

struct Token {
  TokenType type;
  npc_word_t value;
  std::string text;
};

static std::vector<Token> tokens;
static size_t pos = 0;
static bool parse_ok = true;

// tokenizer
static bool make_token(const char *e) {
  tokens.clear();

  int i = 0;

  while (e[i] != '\0') {
    if (isspace((unsigned char)e[i])) {
      i++;
      continue;
    }

    // DEC OR HEX
    if (isdigit((unsigned char)e[i])) {
      int start = i;

      if (e[i] == '0' && (e[i + 1] == 'x' || e[i + 1] == 'X')) {
        i += 2;
        while (isxdigit((unsigned char)e[i]))
          i++;
      } else {
        while (isdigit((unsigned char)e[i]))
          i++;
      }
      std::string num_str(e + start, i - start);
      Token t;

      t.type = TK_NUM;
      t.value = static_cast<npc_word_t>(strtoull(num_str.c_str(), nullptr, 0));
      t.text = num_str;
      tokens.push_back(t);
      continue;
    }

    // register like $pc, $a0
    if (e[i] == '$') {
      i++;
      int start = i;

      while (isalnum((unsigned char)e[i]) || e[i] == '_')
        i++;

      if (start == i) {
        printf("Bad register token near '$'\n");
        return false;
      }

      Token t;
      t.type = TK_REG;
      t.value = 0;
      t.text = std::string(e + start, i - start);
      tokens.push_back(t);
      continue;
    }

    // two-character operator
    if (e[i] == '=' && e[i + 1] == '=') {
      tokens.push_back({TK_EQ, 0, "=="});
      i += 2;
      continue;
    }

    if (e[i] == '!' && e[i + 1] == '=') {
      tokens.push_back({TK_NEQ, 0, "!="});
      i += 2;
      continue;
    }

    if (e[i] == '&' && e[i + 1] == '&') {
      tokens.push_back({TK_AND, 0, "&&"});
      i += 2;
      continue;
    }

    if (e[i] == '|' && e[i + 1] == '|') {
      tokens.push_back({TK_OR, 0, "||"});
      i += 2;
      continue;
    }

    // single character operator
    switch (e[i]) {
    case '+':
      tokens.push_back({TK_PLUS, 0, "+"});
      i++;
      break;

    case '-':
      tokens.push_back({TK_MINUS, 0, "-"});
      i++;
      break;

    case '*':
      tokens.push_back({TK_MUL, 0, "*"});
      i++;
      break;

    case '/':
      tokens.push_back({TK_DIV, 0, "/"});
      i++;
      break;

    case '!':
      tokens.push_back({TK_NOT, 0, "!"});
      i++;
      break;

    case '(':
      tokens.push_back({TK_LPAREN, 0, "("});
      i++;
      break;

    case ')':
      tokens.push_back({TK_RPAREN, 0, ")"});
      i++;
      break;

    default:
      printf("Unknown token near: %c\n", e[i]);
      return false;
    }
  }
  return true;
}

static bool match(TokenType type) {
  if (pos < tokens.size() && tokens[pos].type == type) {
    pos++;
    return true;
  }
  return false;
}

static bool peek(TokenType type) {
  return pos < tokens.size() && tokens[pos].type == type;
}

// recursivedescent parser
// priority from low to high
//   ||
//   &&
//   == !=
//   + -
//   * /
//   unary: -, !, dereference *
//   primary

static npc_word_t parse_or();
static npc_word_t parse_and();
static npc_word_t parse_eq();
static npc_word_t parse_add();
static npc_word_t parse_mul();
static npc_word_t parse_unary();
static npc_word_t parse_primary();

static npc_word_t parse_or() {
  npc_word_t lhs = parse_and();

  while (parse_ok && match(TK_OR)) {
    npc_word_t rhs = parse_and();
    lhs = (lhs || rhs) ? 1 : 0;
  }
  return lhs;
}

static npc_word_t parse_and() {
  npc_word_t lhs = parse_eq();

  while (parse_ok && match(TK_AND)) {
    npc_word_t rhs = parse_eq();
    lhs = (lhs && rhs) ? 1 : 0;
  }
  return lhs;
}

static npc_word_t parse_eq() {
  // deal with the left hand side expression
  npc_word_t lhs = parse_add();

  while (parse_ok && (peek(TK_EQ) || peek(TK_NEQ))) {
    if (match(TK_EQ)) {
      npc_word_t rhs = parse_add();
      lhs = (lhs == rhs) ? 1 : 0;
    } else if (match(TK_NEQ)) {
      npc_word_t rhs = parse_add();
      lhs = (lhs != rhs) ? 1 : 0;
    }
  }
  return lhs;
}

static npc_word_t parse_add() {
  npc_word_t lhs = parse_mul();

  while (parse_ok && (peek(TK_PLUS) || peek(TK_MINUS))) {
    if (match(TK_PLUS)) {
      npc_word_t rhs = parse_mul();
      lhs = lhs + rhs;
    } else if (match(TK_MINUS)) {
      npc_word_t rhs = parse_mul();
      lhs = lhs - rhs;
    }
  }
  return lhs;
}

static npc_word_t parse_mul() {
  npc_word_t lhs = parse_unary();

  while (parse_ok && (peek(TK_MUL) || peek(TK_DIV))) {
    if (match(TK_MUL)) {
      npc_word_t rhs = parse_unary();
      lhs = lhs * rhs;
    } else if (match(TK_DIV)) {
      npc_word_t rhs = parse_unary();

      if (rhs == 0) {
        printf("Divide by zero\n");
        parse_ok = false;
        return 0;
      }

      lhs = lhs / rhs;
    }
  }
  return lhs;
}

static npc_word_t parse_unary() {
  if (match(TK_MINUS)) {
    npc_word_t val = parse_unary();
    return npc_word_t{0} - val;
  }

  if (match(TK_NOT)) {
    npc_word_t val = parse_unary();
    return val == 0 ? 1 : 0;
  }

  // dereference
  if (match(TK_MUL)) {
    npc_word_t addr = parse_unary();
    return paddr_read(static_cast<uint32_t>(addr), 4);
  }
  return parse_primary();
}

static npc_word_t parse_primary() {
  if (pos >= tokens.size()) {
    printf("Unexpected end of expression\n");
    parse_ok = false;
    return 0;
  }

  if (match(TK_LPAREN)) {
    npc_word_t val = parse_or();
    if (!match(TK_RPAREN)) {
      printf("missing ')'\n");
      parse_ok = false;
      return 0;
    }
    return val;
  }
  if (tokens[pos].type == TK_NUM) {
    npc_word_t val = tokens[pos].value;
    pos++;
    return val;
  }

  if (tokens[pos].type == TK_REG) {
    std::string reg_name = tokens[pos].text;
    pos++;

    npc_word_t val = 0;
    if (!npc_reg_str2val(reg_name.c_str(), &val)) {
      printf("Unknown register $%s\n", reg_name.c_str());
      parse_ok = false;
      return 0;
    }
    return val;
  }
  printf("Bad expression near token: %s\n", tokens[pos].text.c_str());
  parse_ok = false;
  return 0;
}

// external interface
npc_word_t expr(const char *e, bool *success) {
  if (success != nullptr)
    *success = false;

  if (e == nullptr)
    return 0;

  if (!make_token(e))
    return 0;

  pos = 0;
  parse_ok = true;

  npc_word_t result = parse_or();

  if (!parse_ok)
    return 0;

  if (pos != tokens.size()) {
    printf("Unexpected token: %s\n", tokens[pos].text.c_str());
    return 0;
  }

  if (success != nullptr)
    *success = true;

  return result;
}
