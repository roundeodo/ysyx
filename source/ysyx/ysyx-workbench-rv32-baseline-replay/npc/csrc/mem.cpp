#include "mem.h"
#include "trace.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>

uint8_t pmem[MEM_SIZE];
// W25Q128 has 128Mbit
static constexpr uint32_t FLASH_SIZE = 16u * 1024u * 1024u;
static constexpr uint32_t FLASH_BASE = 0x30000000u;

static uint8_t flash_mem[FLASH_SIZE];
static bool flash_initialized = false;

static long img_size = 0;
static constexpr uint32_t SERIAL_PORT = 0x10000000;
static struct termios saved_termios;
static bool terminal_modified = false;

static void flash_store32(uint32_t offset, uint32_t value) {
  if (offset > FLASH_SIZE - sizeof(uint32_t)) {
    fprintf(stderr, "Error: flash_store32 out of bound, offset = 0x%08x\n",
            offset);
    exit(1);
  }
  flash_mem[offset + 0] = static_cast<uint8_t>((value >> 0) & 0xffu);
  flash_mem[offset + 1] = static_cast<uint8_t>((value >> 8) & 0xffu);
  flash_mem[offset + 2] = static_cast<uint8_t>((value >> 16) & 0xffu);
  flash_mem[offset + 3] = static_cast<uint8_t>((value >> 24) & 0xffu);
}

void init_flash() {
  memset(flash_mem, 0xff, sizeof(flash_mem));

  flash_store32(0x0000u, 0x12345678u);
  flash_store32(0x0004u, 0xdeadbeefu);
  flash_store32(0x0100u, 0xabcdef01u);

  flash_initialized = true;
}

void load_flash_bin(const char *path) {
  if (path == nullptr) {
    return;
  }

  FILE *file = fopen(path, "rb");
  if (file == nullptr) {
    perror("Error opening flash image");
    exit(1);
  }

  fseek(file, 0, SEEK_END);
  const long image_size = ftell(file);
  fseek(file, 0, SEEK_SET);

  if (image_size < 0 || static_cast<uint64_t>(image_size) > FLASH_SIZE) {
    fprintf(stderr, "Flash image is too large\n");
    fclose(file);
    exit(1);
  }

  memset(flash_mem, 0xff, sizeof(flash_mem));

  const size_t loaded_size =
      fread(flash_mem, 1, static_cast<size_t>(image_size), file);

  fclose(file);

  if (loaded_size != static_cast<size_t>(image_size)) {
    fprintf(stderr, "Failed to load complete flash image\n");
    exit(1);
  }

  flash_initialized = true;
  printf("NPC: loaded %ld bytes into flash\n", image_size);
}

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
  if (paddr < LEGACY_PMEM_BASE || paddr >= LEGACY_PMEM_BASE + MEM_SIZE)
    return nullptr;

  return pmem + (paddr - LEGACY_PMEM_BASE);
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
  if (addr == 0x02000048) {
    rtc_latch = get_time_mus() - start_time;
    return (uint32_t)rtc_latch;
  }
  // rtc high 32 bits
  if (addr == 0x0200004c)
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

void flash_read(int32_t addr, int32_t *data) {
  if (data == nullptr) {
    fprintf(stderr, "Error: flash_read received null data pointer\n");
    abort();
  }

  if (!flash_initialized) {
    init_flash();
  }

  const uint32_t offset = static_cast<uint32_t>(addr);

  if ((offset & 0x3u) != 0 || offset > FLASH_SIZE - sizeof(uint32_t)) {
    fprintf(stderr, "Error: invalid flash read offset = 0x%08x\n", offset);
    abort();
  }

  const uint32_t value = (static_cast<uint32_t>(flash_mem[offset + 0])) |
                         (static_cast<uint32_t>(flash_mem[offset + 1]) << 8) |
                         (static_cast<uint32_t>(flash_mem[offset + 2]) << 16) |
                         (static_cast<uint32_t>(flash_mem[offset + 3]) << 24);

  *data = static_cast<int32_t>(value);
}

void mrom_read(int32_t addr, int32_t *data) {
  const uint32_t read_addr = static_cast<uint32_t>(addr) & ~0x3u;

  if (read_addr < MROM_BASE || read_addr >= MROM_BASE + MROM_SIZE) {
    *data = 0;
    return;
  }

  const uint32_t image_offset = read_addr - MROM_BASE;
  uint32_t read_data = 0;
  for (uint32_t byte_index = 0; byte_index < 4; byte_index++) {
    if (image_offset + byte_index < static_cast<uint32_t>(img_size)) {
      read_data |= static_cast<uint32_t>(pmem[image_offset + byte_index])
                   << (8 * byte_index);
    }
  }
  *data = static_cast<int32_t>(read_data);
}

uint64_t pmem_read_data(uint32_t raddr, int transfer_byte_count,
                        int memory_beat_byte_count) {
  assert(memory_beat_byte_count == 4 || memory_beat_byte_count == 8);
  assert(transfer_byte_count > 0 &&
         transfer_byte_count <= memory_beat_byte_count);

  if (raddr == SERIAL_PORT) {
    const uint64_t data = static_cast<uint8_t>(serial_getchar_nonblock());
    trace_mem_read(raddr, transfer_byte_count, data);
    return data;
  }

  const uint32_t aligned_addr =
      raddr & ~static_cast<uint32_t>(memory_beat_byte_count - 1);
  uint8_t *const host_addr = guest_to_host(aligned_addr);
  if (host_addr == nullptr ||
      aligned_addr > LEGACY_PMEM_BASE + MEM_SIZE - memory_beat_byte_count) {
    fprintf(stderr,
            "Error: pmem_read_data out of bound, addr = 0x%08x, beat = %d\n",
            raddr, memory_beat_byte_count);
    return 0;
  }

  uint64_t memory_beat_data = 0;
  for (int byte_index = 0; byte_index < memory_beat_byte_count; byte_index++) {
    memory_beat_data |= static_cast<uint64_t>(host_addr[byte_index])
                        << (8 * byte_index);
  }

  const int transfer_bit_offset =
      static_cast<int>(raddr - aligned_addr) * 8;
  uint64_t transfer_mask = ~uint64_t{0};
  if (transfer_byte_count < 8) {
    transfer_mask = (uint64_t{1} << (transfer_byte_count * 8)) - 1;
  }
  trace_mem_read(raddr, transfer_byte_count,
                 (memory_beat_data >> transfer_bit_offset) & transfer_mask);
  return memory_beat_data;
}

void pmem_write(uint32_t waddr, uint64_t wdata, uint8_t wmask,
                int memory_beat_byte_count) {
  assert(memory_beat_byte_count == 4 || memory_beat_byte_count == 8);

  const uint32_t aligned_addr =
      waddr & ~static_cast<uint32_t>(memory_beat_byte_count - 1);
  int first_written_byte_index = -1;
  int written_byte_count = 0;
  uint64_t trace_data = 0;

  for (int byte_index = 0; byte_index < memory_beat_byte_count; byte_index++) {
    if (((wmask >> byte_index) & 1u) == 0) {
      continue;
    }
    if (first_written_byte_index < 0) {
      first_written_byte_index = byte_index;
    }
    const uint8_t byte_data = static_cast<uint8_t>(wdata >> (8 * byte_index));
    trace_data |= static_cast<uint64_t>(byte_data) << (8 * written_byte_count);
    written_byte_count++;
  }

  if (first_written_byte_index < 0) {
    return;
  }

  const uint32_t first_written_addr =
      aligned_addr + static_cast<uint32_t>(first_written_byte_index);
  if (first_written_addr == SERIAL_PORT) {
    putchar(static_cast<int>(trace_data & 0xffu));
    fflush(stdout);
    return;
  }

  uint8_t *const host_addr = guest_to_host(aligned_addr);
  if (host_addr == nullptr ||
      aligned_addr > LEGACY_PMEM_BASE + MEM_SIZE - memory_beat_byte_count) {
    fprintf(stderr,
            "Error: pmem_write out of bound, addr = 0x%08x, beat = %d\n",
            waddr, memory_beat_byte_count);
    return;
  }

  trace_mem_write(first_written_addr, written_byte_count, trace_data);
  for (int byte_index = 0; byte_index < memory_beat_byte_count; byte_index++) {
    if ((wmask >> byte_index) & 1u) {
      host_addr[byte_index] = static_cast<uint8_t>(wdata >> (8 * byte_index));
    }
  }
}
}
