#ifndef __YSYXSOC_FLASH_H__
#define __YSYXSOC_FLASH_H__

#include <stdint.h>

/* 通过SPI master读取Flash内部24位地址addr处的连续4个字节。 */
uint32_t flash_read(uint32_t addr);

#endif
