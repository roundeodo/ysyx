#include <stdio.h>

void print_names_ages(int *ages, char **names, int count) {
  int i = 0;
  for (i = 0; i < count; i++) {
    printf("%s is %d years old\n", names[i], ages[i]);
  }
}

int main(int argc, char *argv[]) {
  // create two arrays we care about
  int ages_data[] = {23, 43, 12, 89, 2};
  int *ages = ages_data;
  char *names[] = {"Alan", "Frank", "Mary", "John", "Lisa"};

  // safely get the size of ages
  int count = sizeof(ages_data) / sizeof(int);
  int i = 0;

  // first way using indexing
  print_names_ages(ages, names, count);

  printf("---\n");

  // setup the pointers to the start of the arrays
  int *cur_age = ages;
  char **cur_name = names;

  // second way using pointers
  for (i = 0; i < count; i++) {
    printf("%s is %d years old.\n", *(cur_name + i), *(cur_age + i));
  }

  printf("---\n");

  // third way, pointers are just arrays
  for (i = 0; i < count; i++) {
    printf("%s is %d years old again.\n", *(cur_name + i), *(cur_age + i));
  }

  printf("---\n");

  // fourth way with pointers in a stupid complex way
  for (cur_name = names, cur_age = ages; (cur_age - ages) < count;
       cur_name++, cur_age++) {
    printf("%s lived %d years so far.\n", *cur_name, *cur_age);
  }

  char **cur_arg = argv;
  while (cur_arg < (argv + argc)) {
    printf("arg: %s\n", *cur_arg);
    cur_arg++;
  }

  printf("address of ages is %p  %p\n", ages, &ages[0]);
  printf("value of ages[0] = %d\n", *&ages[0]);

  for (int i = 0; i < count; i++) {
    printf("the address of pointer %d is %p\n", i, (ages + i));
  }

  for (int i = 0; i < count; i++) {
    printf("the address of pointer %d is %p\n", i, (void *)(ages + i));
  }
  return 0;
}
