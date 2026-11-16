#include "dbg.h"
#include "ex22.h"
#include <stdio.h>

double *ratio_hacker_ptr = NULL;
int get_age(struct State *state) { return state->the_age; }

void set_age(struct State *state, int age) { state->the_age = age; }

double update_ratio(double new_ratio) {
  static double ratio = 1.0;

  if (ratio_hacker_ptr == NULL)
    ratio_hacker_ptr = &ratio;
  double old_ratio = ratio;
  ratio = new_ratio;

  return old_ratio;
}

void print_size(struct State *state) {
  log_info("I think size is: %d", state->the_size);
}
