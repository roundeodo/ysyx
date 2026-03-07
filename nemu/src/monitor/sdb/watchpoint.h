#ifndef __WATCHPOINT_H__
#define __WATCHPOINT_H__

typedef struct watchpoint {
  int NO;
  struct watchpoint *next;

  /* TODO: Add more members if necessary */
  char user_expression[128];
  word_t old_value;
} WP;
void init_wp_pool();
WP *new_wp();
void free_wp(WP *wp);
void watchpoint_scan();
void watchpoint_list();
bool delete_wp_by_number(int number);
#endif