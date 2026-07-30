#include <am.h>
#include <stdint.h>

#define YSYXSOC_FRAMEBUFFER_BASE 0x21000000u
#define YSYXSOC_SCREEN_WIDTH     640
#define YSYXSOC_SCREEN_HEIGHT    480

static volatile uint32_t *const framebuffer_pixel_array =
    (volatile uint32_t *)(uintptr_t)YSYXSOC_FRAMEBUFFER_BASE;

void __am_gpu_init(void) {
}

void __am_gpu_config(AM_GPU_CONFIG_T *config) {
  config->present   = true;
  config->has_accel = false;
  config->width     = YSYXSOC_SCREEN_WIDTH;
  config->height    = YSYXSOC_SCREEN_HEIGHT;
  config->vmemsz    = YSYXSOC_SCREEN_WIDTH * YSYXSOC_SCREEN_HEIGHT *
                      sizeof(uint32_t);
}

void __am_gpu_status(AM_GPU_STATUS_T *status) {
  status->ready = true;
}

void __am_gpu_fbdraw(AM_GPU_FBDRAW_T *draw_request) {
  if (draw_request->pixels == NULL || draw_request->w <= 0 ||
      draw_request->h <= 0) {
    return;
  }

  const uint32_t *source_pixel_array = draw_request->pixels;

  for (int source_y = 0; source_y < draw_request->h; source_y++) {
    int screen_y = draw_request->y + source_y;
    if (screen_y < 0 || screen_y >= YSYXSOC_SCREEN_HEIGHT) {
      continue;
    }

    for (int source_x = 0; source_x < draw_request->w; source_x++) {
      int screen_x = draw_request->x + source_x;
      if (screen_x < 0 || screen_x >= YSYXSOC_SCREEN_WIDTH) {
        continue;
      }

      framebuffer_pixel_array[screen_y * YSYXSOC_SCREEN_WIDTH + screen_x] =
          source_pixel_array[source_y * draw_request->w + source_x];
    }
  }

  // NVBoard consumes the continuously generated VGA scan stream, so a
  // software-triggered framebuffer synchronization register is unnecessary.
  (void)draw_request->sync;
}
