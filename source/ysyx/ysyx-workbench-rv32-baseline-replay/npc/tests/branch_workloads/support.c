#include <stddef.h>
int isspace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }
int isdigit(int c) { return c >= '0' && c <= '9'; }
int isalpha(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
char *strchr(const char *text, int value) {
  do { if ((unsigned char)*text == (unsigned char)value) return (char *)text; } while (*text++);
  return NULL;
}
