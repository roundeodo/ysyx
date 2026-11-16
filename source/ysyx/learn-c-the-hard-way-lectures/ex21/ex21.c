#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

int main() {
  printf("--- [stdint.h Size Verification] ---\n\n");

  printf("uint32_t:      %zu bytes (Exact 32-bit)\n", sizeof(uint32_t));

  // compare the size of least and fast int variable
  printf("int_least16_t: %zu bytes (Smallest at least 16-bit)\n",
         sizeof(int_least16_t));
  printf("int_fast16_t:  %zu bytes (Fastest at least 16-bit)\n",
         sizeof(int_fast16_t));

  printf("intptr_t:      %zu bytes (Must fit a pointer address)\n",
         sizeof(intptr_t));

  printf("\n--- [System Limits Macros] ---\n");
  printf("SIZE_MAX:      %ju (Max value for size_t)\n", (uintmax_t)SIZE_MAX);
  printf("PTRDIFF_MAX:   %jd (Max distance between pointers)\n",
         (intmax_t)PTRDIFF_MAX);
  printf("INT64_MAX:     %" PRId64 "\n", INT64_MAX);

  return 0;
}
