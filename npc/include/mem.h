#ifndef __MEM_H__
#define __MEM_H__

#include <cstdint>

#define RESET_VECTOR 0x80000000u
#define MEM_SIZE 0x8000000

extern uint8_t pmem[];

void load_bin(const char *path);
long get_img_size();

uint32_t paddr_read(uint32_t addr, int len);
void paddr_write(uint32_t addr, int len, uint32_t data);

extern "C" int pmem_read(int raddr);
extern "C" void pmem_write(int waddr, int wdata, char wmask);
extern "C" int pmem_read_data(int raddr, int len);
#endif
