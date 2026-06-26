#include "watchpoint.h"
#include "expr.h"

#include <stdint.h>
#include <stdio.h>
#include <string>

#define NR_WP 32

struct WP {
  int NO;
  std::string expr_str;
  uint32_t last_value;
  WP *next;
};

static WP wp_pool[NR_WP];
static WP *head = nullptr;
static WP *free_ = nullptr;

// initialization
void init_wp_pool() {
  for (int i = 0; i < NR_WP; i++) {
    wp_pool[i].NO = i;
    wp_pool[i].expr_str = "";
    wp_pool[i].last_value = 0;
    wp_pool[i].next = (i == NR_WP - 1) ? nullptr : &wp_pool[i + 1];
  }
  head = nullptr;
  free_ = wp_pool;
}

// new watchpoint
void new_wp(const char *expr_str) {
  if (expr_str == nullptr || expr_str[0] == '\0') {
    printf("Usage: w EXPR\n");
    return;
  }

  bool success = false;
  uint32_t value = expr(expr_str, &success);

  if (!success) {
    printf("Bad expression, watchpoint not created\n");
    return;
  }

  if (free == nullptr) {
    printf("No free watchpoint\n");
    return;
  }

  WP *wp = free_;
  free_ = free_->next;

  wp->expr_str = expr_str;
  wp->last_value = value;
  wp->next = head;
  head = wp;

  printf("Watchpoint %d: %s = 0x%08x (%u)\n", wp->NO, wp->expr_str.c_str(),
         wp->last_value, wp->last_value);
}

// delete watchpoint
void free_wp(int no) {
  WP *prev = nullptr;
  WP *cur = head;

  while (cur != nullptr) {
    if (cur->NO == no) {
      if (prev == nullptr) {
        head = cur->next;
      } else {
        prev->next = cur->next;
      }
      cur->expr_str = "";
      cur->last_value = 0;

      cur->next = free_;
      free_ = cur;

      printf("Watchpoint %d deleted\n", no);
      return;
    }
    prev = cur;
    cur = cur->next;
  }
  printf("No watchpoint %d\n", no);
}

// print all watchpoint
void display_watchpoints() {
  if (head == nullptr) {
    printf("No watchpoints.\n");
    return;
  }

  printf("Num\tValue\t\tExpression\n");

  for (WP *wp = head; wp != nullptr; wp = wp->next) {
    printf("%d\t0x%08x\t%s\n", wp->NO, wp->last_value, wp->expr_str.c_str());
  }
}

// check watchpoints
bool check_watchpoints() {
  bool triggered = false;

  for (WP *wp = head; wp != nullptr; wp = wp->next) {
    bool success = false;
    uint32_t new_value = expr(wp->expr_str.c_str(), &success);

    if (!success) {
      printf("Watchpoint %d expression becomes invalid: %s\n", wp->NO,
             wp->expr_str.c_str());
      triggered = true;
      continue;
    }

    if (new_value != wp->last_value) {
      printf("\nWatchpoint %d triggered:\n", wp->NO);
      printf("  expr: %s\n", wp->expr_str.c_str());
      printf("  old : 0x%08x (%u)\n", wp->last_value, wp->last_value);
      printf("  new : 0x%08x (%u)\n", new_value, new_value);

      wp->last_value = new_value;
      triggered = true;
    }
  }

  return triggered;
}
