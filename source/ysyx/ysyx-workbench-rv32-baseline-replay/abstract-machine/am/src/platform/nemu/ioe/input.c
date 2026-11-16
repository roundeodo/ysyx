#include <am.h>
#include <nemu.h>

#define KEYDOWN_MASK 0x8000
//0b 1000 0000 0000 0000
void __am_input_keybrd(AM_INPUT_KEYBRD_T *kbd) {
  uint32_t keyboard_data = inl(KBD_ADDR);
  kbd->keydown = (keyboard_data & KEYDOWN_MASK) != 0;
  kbd->keycode = keyboard_data & ~KEYDOWN_MASK;
}
