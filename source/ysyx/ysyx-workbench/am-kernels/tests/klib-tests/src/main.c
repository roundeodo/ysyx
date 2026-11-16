#include <am.h>
#include <klib.h>
#include <test.h>

int main() {
  test_memory();
  test_string();
  test_stdio();

  printf("All klib tests passed!\n");

  return 0;
}