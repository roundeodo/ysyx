#include <flash.h>
#include <stdint.h>

int main(void) {
  if (flash_read(0x000000u) != 0x12345678u) {
    return 1;
  }

  if (flash_read(0x000004u) != 0xdeadbeefu) {
    return 2;
  }

  if (flash_read(0x000100u) != 0xabcdef01u) {
    return 3;
  }

  return 0;
}
