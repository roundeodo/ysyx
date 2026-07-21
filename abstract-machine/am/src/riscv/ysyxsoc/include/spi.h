#ifndef __YSYXSOC_SPI_H__
#define __YSYXSOC_SPI_H__

#include <stdbool.h>
#include <stdint.h>

typedef enum {
  SPI_CLOCK_EDGE_RISING,
  SPI_CLOCK_EDGE_FALLING,
} spi_clock_edge_e;

typedef struct {
  uint8_t          slave_select_index;
  uint8_t          transfer_bit_count;
  uint16_t         clock_divider;
  spi_clock_edge_e transmit_change_edge;
  spi_clock_edge_e receive_sample_edge;
  bool             least_significant_bit_first;
} spi_transfer_config_t;

void spi_init(void);

/*
 * 使用SPI master完成一次1到64位的全双工事务。
 *
 * transmit_data中参与传输的低transfer_bit_count位有效。MSB-first模式下，
 * 这些有效位中的最高位最先发出。返回值采用相同的位位置保存接收数据。
 */
uint64_t spi_transfer64(const spi_transfer_config_t *config,
                        uint64_t                     transmit_data);

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
