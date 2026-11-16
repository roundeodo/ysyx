#include <am.h>
#include <nemu.h>

#define AUDIO_FREQ_ADDR      (AUDIO_ADDR + 0x00)
#define AUDIO_CHANNELS_ADDR  (AUDIO_ADDR + 0x04)
#define AUDIO_SAMPLES_ADDR   (AUDIO_ADDR + 0x08)
#define AUDIO_SBUF_SIZE_ADDR (AUDIO_ADDR + 0x0c)
#define AUDIO_INIT_ADDR      (AUDIO_ADDR + 0x10)
#define AUDIO_COUNT_ADDR     (AUDIO_ADDR + 0x14)

void __am_audio_init() {
}

void __am_audio_config(AM_AUDIO_CONFIG_T *cfg) {
  cfg->present = true;
  cfg->bufsize = inl(AUDIO_SBUF_SIZE_ADDR);
}

void __am_audio_ctrl(AM_AUDIO_CTRL_T *ctrl) {
  outl(AUDIO_FREQ_ADDR, ctrl->freq);
  outl(AUDIO_CHANNELS_ADDR, ctrl->channels);
  outl(AUDIO_SAMPLES_ADDR, ctrl->samples);
  outl(AUDIO_INIT_ADDR, 1);
} 

void __am_audio_status(AM_AUDIO_STATUS_T *stat) {
  stat->count = inl(AUDIO_COUNT_ADDR);
}

void __am_audio_play(AM_AUDIO_PLAY_T *ctl) {
  uint32_t len = ctl->buf.end - ctl->buf.start;
  uint8_t *data = (uint8_t *)ctl->buf.start;

  uint8_t *sbuf = (uint8_t *)(uintptr_t)AUDIO_SBUF_ADDR;
  uint32_t sbuf_size = inl(AUDIO_SBUF_SIZE_ADDR);

  static uint32_t write_pos = 0;
  while(len>0){
    uint32_t count = inl(AUDIO_COUNT_ADDR);
    uint32_t free_space = sbuf_size - count;

    if(free_space > 0){
      uint32_t write_len = (len < free_space) ? len : free_space;
      if(write_pos + write_len > sbuf_size){
        uint32_t first_part = sbuf_size - write_pos;
        uint32_t second_part = write_len - first_part;
        for (uint32_t i = 0; i < first_part; i++){
          sbuf[write_pos + i] = data[i];
        }
        for (uint32_t i = 0; i < second_part; i++){
          sbuf[i] = data[first_part + i];
        }
        write_pos = second_part; // the final position after the loop
      }
      else{
        for (uint32_t i = 0; i < write_len; i++){
          sbuf[write_pos + i] = data[i];
        }
        write_pos += write_len;
      }
      data += write_len; // we might no send all the data in single trannsfer
      len -= write_len;
      outl(AUDIO_COUNT_ADDR, count + write_len);
    }
  }
}
