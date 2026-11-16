#include <am.h>
#include <klib-macros.h>
#include <stdlib.h>
#define h 300
#define w 400
#define R(p) (((p) >> 16) & 0xff)
#define G(p) (((p) >> 8) & 0xff)
#define B(p) ((p)&0xff)
#define normal_interval 20
#define fast_interval 2

uint32_t color_list[] = {0x000000, 0xff0000, 0x00ff00, 0x0000ff,
                         0xffff00, 0xff00ff, 0x00ffff, 0xffffff};

static uint32_t c_start = 0;
static uint32_t c_end = 0;
static int k_steps = 100;
static int i_step = 0;
static int cur_idx = 0;

void color_transition() {
  if (i_step >= k_steps) {
    c_start = c_end;
    int num_color = sizeof(color_list) / sizeof(uint32_t);
    int offset = rand() % (num_color - 1);
    cur_idx = (cur_idx + 1 + offset) % num_color;
    c_end = color_list[cur_idx];
    i_step = 0;
  }
  i_step++;
}

void draw() {
  // add code here
  static uint32_t pixels[w * h];

  int r0 = R(c_start), rk = R(c_end);
  int g0 = G(c_start), gk = G(c_end);
  int b0 = B(c_start), bk = B(c_end);

  uint8_t ri = r0 + (rk - r0) * i_step / k_steps;
  uint8_t gi = g0 + (gk - g0) * i_step / k_steps;
  uint8_t bi = b0 + (bk - b0) * i_step / k_steps;

  uint32_t color = (ri << 16) | (gi << 8) | bi;

  for (int i = 0; i < w * h; i++) {
    pixels[i] = color;
  }
  io_write(AM_GPU_FBDRAW, 0, 0, pixels, w, h, true);
}

int main() {
  ioe_init(); // initialization for GUI
  c_end = color_list[rand() % 8];
  uint32_t last_time = 0;
  uint32_t current_interval = normal_interval;
  while (1) {
    AM_INPUT_KEYBRD_T ev = io_read(AM_INPUT_KEYBRD);
    uint32_t now = io_read(AM_TIMER_UPTIME).us / 1000;
    if (ev.keycode != AM_KEY_NONE) {
      if (ev.keydown) {
        if (ev.keycode == AM_KEY_ESCAPE) {
          halt(0);
        } else {
          current_interval = fast_interval;
        }
      } else {
        current_interval = normal_interval;
      }
    }
    if (now - last_time > current_interval) {
      color_transition();
      draw();
      last_time = now;
    }
  }
  return 0;
}
