/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <common.h>
#include <device/map.h>
#include <SDL2/SDL.h>


enum {
  reg_freq,
  reg_channels,
  reg_samples,
  reg_sbuf_size,
  reg_init,
  reg_count,
  nr_reg
};

static uint8_t *sbuf = NULL;
static uint32_t *audio_base = NULL;


static uint32_t audio_count = 0;  // for monitoring the sbuf queue
static uint32_t audio_tail = 0;

static void audio_play_callback(void *userdata, uint8_t *stream, int len){
  int len_to_play = (audio_count < len) ? audio_count : len;
  for (int i = 0; i < len_to_play; i++){
    stream[i] = sbuf[(audio_tail + i) % CONFIG_SB_SIZE]; //loop buffer
  }
  audio_tail = (audio_tail + len_to_play) % CONFIG_SB_SIZE;
  audio_count -= len_to_play;

  if(len_to_play < len){
    memset(stream + len_to_play, 0, len - len_to_play);
  }
}


static void audio_io_handler(uint32_t offset, int len, bool is_write) {
  if(is_write){
    switch(offset){
      case reg_init * 4: // one reg takes 4 byte and here reg_init = 4 which is just index,and we have to turn it into address with offsettttttttttt
        SDL_InitSubSystem(SDL_INIT_AUDIO);
        SDL_AudioSpec spec = {0};
        spec.freq = audio_base[reg_freq];
        spec.channels = audio_base[reg_channels];
        spec.samples = audio_base[reg_samples];
        spec.format = AUDIO_S16SYS;
        spec.userdata = NULL;
        spec.callback = audio_play_callback;
        SDL_OpenAudio(&spec, NULL);
        SDL_PauseAudio(0);
        break;
      case reg_count * 4:
        audio_count = audio_base[reg_count];
        break;
    }
  }
  else{
    switch(offset){
      case reg_count * 4:
        audio_base[reg_count] = audio_count;
        break;
    }
  }
}

void init_audio() {
  uint32_t space_size = sizeof(uint32_t) * nr_reg;
  audio_base = (uint32_t *)new_space(space_size);
#ifdef CONFIG_HAS_PORT_IO
  add_pio_map ("audio", CONFIG_AUDIO_CTL_PORT, audio_base, space_size, audio_io_handler);
#else
  add_mmio_map("audio", CONFIG_AUDIO_CTL_MMIO, audio_base, space_size, audio_io_handler);
#endif

  sbuf = (uint8_t *)new_space(CONFIG_SB_SIZE);
  add_mmio_map("audio-sbuf", CONFIG_SB_ADDR, sbuf, CONFIG_SB_SIZE, NULL);
  audio_base[reg_sbuf_size] = CONFIG_SB_SIZE;
}
