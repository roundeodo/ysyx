#include "mem.h"
#include "trace.h"
#include <fcntl.h>
#include <cstdio>
#include <cstdlib>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>
uint8_t pmem[MEM_SIZE];

static long img_size = 0;
static constexpr uint32_t SERIAL_PORT = 0x10000000;
static struct termios saved_termios;
static bool terminal_modified = false;

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
  img_size = size;
  fseek(fp, 0, SEEK_SET);
  if (fread(pmem, 1, size, fp) != size) {
    fprintf(stderr, "Error reading bin file\n");
  }
  fclose(fp);
}

long get_img_size() { return img_size; }

uint64_t get_time_mus() {
  struct timeval now;
  gettimeofday(&now, NULL);
  return now.tv_sec * 1000000 + now.tv_usec;
}

// transfer physical address to host address
static uint8_t *guest_to_host(uint32_t paddr) {
  if (paddr < RESET_VECTOR || paddr >= RESET_VECTOR + MEM_SIZE)
    return nullptr;

  return pmem + (paddr - RESET_VECTOR);
}

static void serial_restore_terminal() {
  if (terminal_modified) {
    tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
  }
}

static int serial_getchar_nonblock() {
  static bool inited = false;

  if (!inited) {
    if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &saved_termios) == 0) {
      struct termios term = saved_termios;
      term.c_lflag &= ~(ICANON | ECHO);
      term.c_cc[VMIN] = 0;
      term.c_cc[VTIME] = 0;
      if (tcsetattr(STDIN_FILENO, TCSANOW, &term) == 0) {
        terminal_modified = true;
        atexit(serial_restore_terminal);
      }
    }

    int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    if (flags >= 0) {
      fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
    }
    inited = true;
  }

  unsigned char ch = 0;
  ssize_t n = read(STDIN_FILENO, &ch, 1);
  return n == 1 ? ch : 0xff;
}

uint32_t paddr_read(uint32_t addr, int len) {
  static uint64_t start_time = 0;
  static uint64_t rtc_latch = 0;

  if (start_time == 0)
    start_time = get_time_mus();

  if (addr == SERIAL_PORT) {
    return serial_getchar_nonblock();
  }

  // rtc low 32 bits
  if (addr == 0xa0000048) {
    rtc_latch = get_time_mus() - start_time;
    return (uint32_t)rtc_latch;
  }
  // rtc high 32 bits
  if (addr == 0xa000004c)
    return (uint32_t)(rtc_latch >> 32);

  uint8_t *host_addr = guest_to_host(addr);
  if (host_addr == nullptr) {
    fprintf(stderr, "Error: paddr_read out of bound, addr = 0x%08x, len = %d\n",
            addr, len);
    return 0;
  }

  // normal read
  uint32_t ret = 0;
  for (int i = 0; i < len; i++) {
    ret |= ((uint32_t)host_addr[i] << (8 * i));
  }
  return ret;
}

void paddr_write(uint32_t addr, int len, uint32_t data) {
  if (addr == SERIAL_PORT) {
    putchar(data & 0xff);
    fflush(stdout);
    return;
  }
  if (len != 1 && len != 2 && len != 4) {
    fprintf(stderr, "Error: unsupported paddr_write len = %d\n", len);
    exit(1);
  }

  uint8_t *host_addr = guest_to_host(addr);

  if (host_addr == nullptr) {
    fprintf(stderr,
            "Error: paddr_write out of bound, addr = 0x%08x, len = %d\n", addr,
            len);
    return;
  }

  // normal write
  for (int i = 0; i < len; i++) {
    host_addr[i] = (data >> (8 * i)) & 0xff;
  }
}

extern "C" {

int pmem_read(int raddr) {
  static uint64_t start_time = 0;
  static uint64_t rtc_latch = 0;
  if (start_time == 0)
    start_time = get_time_mus();
  if ((uint32_t)raddr == SERIAL_PORT) {
    return serial_getchar_nonblock();
  }
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
  if ((uint32_t)waddr == SERIAL_PORT) {
    putchar(wdata & 0xff);
    fflush(stdout);
    return;
  }

  uint32_t aligned_addr = waddr & ~0x3u; // reset bit 1 and 0 for aligning
  uint32_t offset = aligned_addr - 0x80000000;
  if (offset >= MEM_SIZE) {
    return;
  }

  int len = 0;
  uint32_t trace_data = 0;
  int shift = -1;

  for (int i = 0; i < 4; i++) {
    if ((wmask >> i) & 0x1) {
      if (shift == -1) {
        shift = i;
      }

      uint8_t byte = (wdata >> (8 * i)) & 0xff;
      trace_data |= ((uint32_t)byte) << (8 * len);
      len++;
    }
  }

  if (len > 0) {
    trace_mem_write((uint32_t)waddr, len, trace_data);
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

int pmem_read_data(int raddr, int len) {
  if ((uint32_t)raddr == SERIAL_PORT) {
    int data = serial_getchar_nonblock();
    trace_mem_read((uint32_t)raddr, len, (uint32_t)data);
    return data;
  }

  uint32_t aligned_addr = ((uint32_t)raddr) & ~0x3u;

  uint32_t raw_word = paddr_read(aligned_addr, 4);

  uint32_t data = paddr_read((uint32_t)raddr, len);

  trace_mem_read((uint32_t)raddr, len, data);

  return (int)raw_word;
}
}
