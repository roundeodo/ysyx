#ifndef __YSYXSOC_SPI_H__
#define __YSYXSOC_SPI_H__

#include <stdint.h>

void spi_init(void);

/*
 * 通过 SPI master 将 input 发给 bitrev slave，
 * 返回硬件计算得到的位反转结果。
 */
uint8_t spi_bitrev(uint8_t input);

/*
 * 执行若干测试向量。
 *
 * 返回：
 *   0：全部通过；
 *   非零：第几个测试向量失败。
 */
int spi_bitrev_self_test(void);

#endif