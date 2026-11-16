#include "dbg.h"
#include "ex22.h"

const char *MY_NAME = "Zed A. Shaw";

void by_value(int a) {
  a = 99; 
}

void by_reference(int *a) {
  *a = 99; 
}

void scope_demo(int count) {
  log_info("count is: %d", count);

  if (count > 10) {
    int numbers = 100; // BAD! BUGS!

    log_info("count in this scope is %d", numbers);
  }

  log_info("count is at exit: %d", count);

  count = 3000;

  log_info("count after assign: %d", count);
  scope_demo(count + 1);
}

int main(int argc, char *argv[]) {
  // test out THE_AGE accessors
  struct State my_state = {.the_age = 37, .the_size = 1000};
  struct State *state = &my_state;
  log_info("My name: %s, age: %d", MY_NAME, get_age(&my_state));

  set_age(&my_state, 100);

  log_info("My age is now: %d", get_age(&my_state));

  // test out THE_SIZE extern
  log_info("THE_SIZE is: %d", my_state.the_size);
  print_size(state);

  log_info("THE SIZE is now: %d", my_state.the_size);
  print_size(state);

  // test the ratio function static
  log_info("Ratio at first: %f", update_ratio(2.0));
  log_info("Ratio again: %f", update_ratio(10.0));
  log_info("Ratio once more: %f", update_ratio(300.0));

  // test the scope demo
  int count = 4;
  scope_demo(count);
  scope_demo(count * 20);

  log_info("count after calling scope_demo: %d", count);

  log_info("Ratio at first: %f", update_ratio(2.0));

  if (ratio_hacker_ptr != NULL) {
    log_info("Hacking! The internal ratio address is: %p",
             (void *)ratio_hacker_ptr);

    *ratio_hacker_ptr = 999.99;
    log_info("Successfully hacked the private variable to 999.99!");
  }

  log_info("Ratio again (should be 999.99): %f", update_ratio(10.0));
  int x = 10;
  by_value(x); 

  printf("by value %d\n", x);
  by_reference(&x); 

  printf("by reference %d\n", x);

  return 0;
}
