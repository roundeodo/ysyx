#include "mem.h"
#include <cstdio>
#include <cstdlib>
#include <sys/time.h>
uint8_t pmem[MEM_SIZE];

void load_bin(const char *path) {
  if (path == nullptr) {
    return;
  }
  FILE *fp = fopen(path, "rb");
  if (fp == nullptr) {
    perror("Error opening bin file"); // being able to use only when this error
                                      // is set by system
    exit(1);
  }
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  if (fread(pmem, 1, size, fp) != size) {
    fprintf(stderr, "Error reading bin file\n");
  }
  fclose(fp);
}

uint64_t get_time_mus() {
  struct timeval now;
  gettimeofday(&now, NULL);
  return now.tv_sec * 1000000 + now.tv_usec;
}

extern "C" {

int pmem_read(int raddr) {
  static uint64_t start_time = 0;
  static uint64_t rtc_latch = 0;
  if (start_time == 0)
    start_time = get_time_mus();
  if (raddr == 0xa0000048) {
    rtc_latch = get_time_mus() - start_time;
    return (uint32_t)rtc_latch;
  }
  if (raddr == 0xa000004c) {
    return (uint32_t)(rtc_latch >> 32);
  }

  uint32_t aligned_addr = raddr & ~0x3u;
  uint32_t offset = aligned_addr - 0x80000000;
  if (offset >= MEM_SIZE) {
    return 0;
  }
  return *(uint32_t *)(pmem + offset);
}

void pmem_write(int waddr, int wdata, char wmask) {
  if (waddr == 0x10000000) {
    putchar(wdata & 0xff);
    fflush(stdout);
    return;
  }

  uint32_t aligned_addr = waddr & ~0x3u; // reset bit 1 and 0 for aligning
  uint32_t offset = aligned_addr - 0x80000000;
  if (offset >= MEM_SIZE) {
    return;
  }

  if (wmask & 0b0001)
    pmem[offset + 0] = (wdata >> 0) & 0xff;
  if (wmask & 0b0010)
    pmem[offset + 1] = (wdata >> 8) & 0xff;
  if (wmask & 0b0100)
    pmem[offset + 2] = (wdata >> 16) & 0xff;
  if (wmask & 0b1000)
    pmem[offset + 3] = (wdata >> 24) & 0xff;
}
}
