#ifndef __MEM_H__
#define __MEM_H__

#include <cstdint>

#define LEGACY_PMEM_BASE 0x80000000u
#define MROM_BASE 0x20000000u
#define MROM_SIZE 0x00001000u
#define SRAM_BASE 0x0f000000u
#define SRAM_SIZE 0x00002000u
#define YSYXSOC_RESET_VECTOR MROM_BASE

#define MEM_SIZE 0x08000000u

extern uint8_t pmem[];

void load_bin(const char *path);
void load_flash_bin(const char *path);

long get_img_size();

uint32_t paddr_read(uint32_t addr, int len);
void paddr_write(uint32_t addr, int len, uint32_t data);

extern "C" int pmem_read(int raddr);
extern "C" void pmem_write(int waddr, int wdata, char wmask);
extern "C" int pmem_read_data(int raddr, int len);
#endif
