#include <flash.h>
#include <spi.h>

#define FLASH_READ_COMMAND          0x03u
#define FLASH_ADDRESS_MASK          0x00ffffffu
#define FLASH_SLAVE_SELECT_INDEX    0u
#define FLASH_TRANSFER_BIT_COUNT   64u
#define FLASH_SPI_CLOCK_DIVIDER      2u

static uint32_t byte_swap32(uint32_t value) {
  return ((value & 0x000000ffu) << 24) |
         ((value & 0x0000ff00u) << 8) |
         ((value & 0x00ff0000u) >> 8) |
         ((value & 0xff000000u) >> 24);
}

uint32_t flash_read(uint32_t addr) {
  const spi_transfer_config_t config = {
      .slave_select_index               = FLASH_SLAVE_SELECT_INDEX,
      .transfer_bit_count               = FLASH_TRANSFER_BIT_COUNT,
      .clock_divider                     = FLASH_SPI_CLOCK_DIVIDER,
      .transmit_change_edge              = SPI_CLOCK_EDGE_FALLING,
      .receive_sample_edge               = SPI_CLOCK_EDGE_RISING,
      .least_significant_bit_first       = false,
  };

  /*
   * 64位事务按MSB-first发送：
   *   [63:56]  0x03读命令
   *   [55:32]  Flash内部24位地址
   *   [31:0]   dummy bit，用于产生32个接收时钟
   */
  const uint64_t command_and_address =
      ((uint64_t)FLASH_READ_COMMAND << 56) |
      ((uint64_t)(addr & FLASH_ADDRESS_MASK) << 32);

  const uint64_t received_data = spi_transfer64(&config, command_and_address);

  /* Flash按地址递增顺序发送字节，RX0中需要转换为RV32小端整数。 */
  return byte_swap32((uint32_t)received_data);
}
