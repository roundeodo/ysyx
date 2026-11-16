#include <am.h>
#include <nemu.h>

#define SYNC_ADDR (VGACTL_ADDR + 4)

void __am_gpu_init() {
  AM_GPU_CONFIG_T vga_config = io_read(AM_GPU_CONFIG);
  int i;
  int w = vga_config.width;  
  int h = vga_config.height;  
  uint32_t *fb = (uint32_t *)(uintptr_t)FB_ADDR;
  for (i = 0; i < w * h; i ++) fb[i] = 0;
  outl(SYNC_ADDR, 1);
}

void __am_gpu_config(AM_GPU_CONFIG_T *cfg) {
  uint32_t vga_config = inl(VGACTL_ADDR);
  uint32_t w = vga_config >> 16;
  uint32_t h = vga_config & 0x0000ffff;
  *cfg = (AM_GPU_CONFIG_T){
      .present = true, .has_accel = false, .width = w, .height = h, .vmemsz = w*h*sizeof(uint32_t)};
}

void __am_gpu_fbdraw(AM_GPU_FBDRAW_T *ctl) { // ctl is GPU_WIDTH / N  which is a piece of the whole screen
  int screen_w = io_read(AM_GPU_CONFIG).width; // whole screen
  if(ctl->pixels != NULL){
    int x = ctl->x;
    int y = ctl->y;
    int w = ctl->w;
    int h = ctl->h;
    uint32_t *pixels = ctl->pixels;
    uint32_t *fb = (uint32_t *)(uintptr_t)FB_ADDR; // +1 = +4byte


    for (int i = 0; i < h; i++){
      for (int j = 0; j < w; j++){
        fb[(y + i) * screen_w + (x + j)] = pixels[i * w + j]; // bypass the whole row
      }
    }
  }
  if (ctl->sync) {
    outl(SYNC_ADDR, 1);
  }
}

void __am_gpu_status(AM_GPU_STATUS_T *status) {
  status->ready = true;
}

