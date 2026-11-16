#include "dbg.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#define MAX_DATA 100

typedef enum EyeColor {
  BLUE_EYES,
  GREEN_EYES,
  BROWN_EYES,
  BLACK_EYES,
  OTHER_EYES
} EyeColor;

const char *EYE_COLOR_NAMES[] = {"Blue", "Green", "Brown", "Black", "Other"};

typedef struct Person {
  int age;
  char first_name[MAX_DATA];
  char last_name[MAX_DATA];
  EyeColor eyes;
  float income;
} Person;

void trim(char *str) {
  if (str == NULL)
    return;

  int len = strlen(str);

  while (len > 0 && isspace((unsigned char)str[len - 1])) {
    str[len - 1] = '\0';
    len--;
  }

  char *start = str;
  while (*start && isspace((unsigned char)*start)) {
    start++;
  }

  if (start != str) {
    memmove(str, start, strlen(start) + 1);
  }
}

int read_string(char *out_string, int max_size) {
  int i = 0;
  char ch = 0;
  int rc = 0;

  for (i = 0; i < max_size - 1; i++) {
    rc = scanf("%c", &ch);
    if (rc != 1)
      break;
    if (ch == '\n')
      break;
    out_string[i] = ch;
  }
  out_string[i] = '\0';
  return i;
}

int main(int argc, char *argv[]) {
  Person you = {.age = 0};
  int i = 0;
  char *in = NULL;
  char line_buffer[MAX_DATA];
  printf("What's your First Name? ");
  in = fgets(you.first_name, MAX_DATA - 1, stdin);
  check(in != NULL, "Failed to read first name.");
  trim(you.first_name);

  printf("What's your Last Name? ");
  in = fgets(you.last_name, MAX_DATA - 1, stdin);
  check(in != NULL, "Failed to read l`ast name.");
  trim(you.last_name);
  printf("How old are you? ");
  char *rc = fgets(line_buffer, MAX_DATA - 1, stdin);
  check(rc != NULL, "input failed");
  you.age = atoi(line_buffer);
  check(you.age > 0, "you have to enter a number");

  printf("What color are your eyes:\n");
  for (i = 0; i <= OTHER_EYES; i++) {
    printf("%d) %s\n", i + 1, EYE_COLOR_NAMES[i]);
  }
  printf("> ");

  int eyes = -1;
  rc = fgets(line_buffer, MAX_DATA - 1, stdin);
  check(rc != NULL, "input failed.");
  eyes = atoi(line_buffer);
  you.eyes = eyes - 1;
  check(you.eyes <= OTHER_EYES && you.eyes >= 0,
        "Do it right, that's not an option.");

  printf("How much do you make an hour? ");
  rc = fgets(line_buffer, MAX_DATA - 1, stdin);
  check(rc != NULL, "input failed ");
  you.income = atof(line_buffer);
  check(you.income >= 0.0, "enter a floating point number.");

  printf("enter a final comment");
  char comment[MAX_DATA];
  read_string(comment, MAX_DATA);
  printf("Your COMMENT WAS %s\n", comment);
  printf("----- RESULTS -----\n");

  printf("First Name: %s", you.first_name);
  printf("Last Name: %s", you.last_name);
  printf("Age: %d\n", you.age);
  printf("Eyes: %s\n", EYE_COLOR_NAMES[you.eyes]);
  printf("Income: %f\n", you.income);

  return 0;
error:

  return -1;
}
