#include "sdb.h"
#include "cpu.h"
#include "expr.h"
#include "mem.h"
#include "watchpoint.h"

#include <iostream>
#include <sstream>
#include <string>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static std::string trim_left(const std::string &s) {
  size_t pos = s.find_first_not_of(" \t\n\r");
  if (pos == std::string::npos) {
    return "";
  }
  return s.substr(pos);
}

// help
static void cmd_help() {
  std::cout << "Supported commands:\n";
  std::cout << "  help             show this message\n";
  std::cout << "  c                continue running\n";
  std::cout << "  q                quit NPC\n";
  std::cout << "  si [N]           step N instructions, default N = 1\n";
  std::cout << "  info r           print registers\n";
  std::cout << "  info w           print watchpoints\n";
  std::cout
      << "  x N EXPR         scan memory from address EXPR, print N words\n";
  std::cout << "  p EXPR           evaluate expression\n";
  std::cout << "  w EXPR           set watchpoint\n";
  std::cout << "  d N              delete watchpoint N\n";
}

// si (when input is "si", only one step will be execute when input is "si 10",
// n = 1 will be overwritten)
static void cmd_si(std::istringstream &iss) {
  uint64_t n = 1;

  iss >> n;

  cpu_exec(n);
}

// info
static void cmd_info(std::istringstream &iss) {
  std::string arg;
  iss >> arg;

  if (arg == "r") {
    npc_dump_regs();
  } else if (arg == "w") {
    display_watchpoints();
  } else {
    std::cout << "Usage: info r | info w\n";
  }
}

// x N EXPR
//   x 4 0x80000000
//   x 8 $pc
//   x 4 $sp + 4
static void cmd_x(std::istringstream &iss) {
  int n = 0;
  iss >> n;

  std::string expr_str;
  std::getline(iss, expr_str);
  expr_str = trim_left(expr_str);

  if (n <= 0 || expr_str.empty()) {
    std::cout << "Usage: x N EXPR\n";
    return;
  }

  bool success = false;
  uint32_t addr = expr(expr_str.c_str(), &success);

  if (!success) {
    std::cout << "Bad expression\n";
    return;
  }

  for (int i = 0; i < n; i++) {
    uint32_t cur_addr = addr + i * 4;
    uint32_t data = paddr_read(cur_addr, 4);

    printf("0x%08x: 0x%08x\n", cur_addr, data);
  }
}

// p EXPR
static void cmd_p(std::istringstream &iss) {
  std::string expr_str;
  std::getline(iss, expr_str);
  expr_str = trim_left(expr_str);

  if (expr_str.empty()) {
    std::cout << "Usage: p EXPR\n";
    return;
  }

  bool success = false;
  uint32_t value = expr(expr_str.c_str(), &success);

  if (!success) {
    std::cout << "Bad expression\n";
    return;
  }
  printf("0x%08x (%u)\n", value, value);
}

// w EXPR
static void cmd_w(std::istringstream &iss) {
  std::string expr_str;
  std::getline(iss, expr_str);
  expr_str = trim_left(expr_str);

  if (expr_str.empty()) {
    std::cout << "Usage: w EXPR\n";
    return;
  }

  new_wp(expr_str.c_str());
}

// d N
static void cmd_d(std::istringstream &iss) {
  int no = -1;
  iss >> no;

  if (no < 0) {
    std::cout << "Usage: d N\n";
    return;
  }

  free_wp(no);
}

// sdb mainloop
void sdb_mainloop() {
  std::string line;
  std::string last_line;

  while (true) {
    std::cout << "(npc)" << std::flush;
    if (!std::getline(std::cin, line)) {
      break;
    }

    if (line.empty()) {
      if (last_line.empty()) {
        continue;
      }
      line = last_line;
    } else {
      last_line = line;
    }

    std::istringstream iss(line);
    std::string cmd;
    iss >> cmd;

    if (cmd == "help") {
      cmd_help();
    } else if (cmd == "c") {
      cpu_exec(UINT64_MAX);
    } else if (cmd == "q") {
      break;
    } else if (cmd == "si") {
      cmd_si(iss);
    } else if (cmd == "info") {
      cmd_info(iss);
    } else if (cmd == "x") {
      cmd_x(iss);
    } else if (cmd == "p") {
      cmd_p(iss);
    } else if (cmd == "w") {
      cmd_w(iss);
    } else if (cmd == "d") {
      cmd_d(iss);
    } else {
      std::cout << "Unknown command:" << cmd << "\n";
      std::cout << "Type 'help' for supported commands\n";
    }
    if (npc_is_halted()) {
      std::cout << "NPC has ended. Use q to quit\n";
    }
  }
}