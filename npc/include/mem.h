#ifndef __MEM_H__
#define __MEM_H__

#include <cstdint>

#define MEM_SIZE 0x8000000

extern uint8_t pmem[];

void load_bin(const char *path);

extern "C" int pmem_read(int raddr);
extern "C" void pmem_write(int waddr, int wdata, char wmask);
#endif