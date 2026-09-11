#include <spi.h>

/* SPI master 在 CPU 地址空间中的 MMIO 基地址。 */
#define SPI_BASE 0x10001000u

/* ------------------------------------------------------------
 * SPI 寄存器字节偏移
 *
 * spi_defines.v 中的 0、1、2……是 32 位寄存器编号，
 * 因此需要乘以 4 才是 CPU 使用的字节地址。
 * ------------------------------------------------------------ */
#define SPI_TXRX0_OFFSET   0x00u
#define SPI_TXRX1_OFFSET   0x04u
#define SPI_TXRX2_OFFSET   0x08u
#define SPI_TXRX3_OFFSET   0x0cu
#define SPI_CTRL_OFFSET    0x10u
#define SPI_DIVIDER_OFFSET 0x14u
#define SPI_SS_OFFSET      0x18u

/* 将一个地址转换为 volatile MMIO 寄存器。 */
#define SPI_REG(offset)                                                   \
  (*(volatile uint32_t *)(uintptr_t)(SPI_BASE + (offset)))

#define SPI_TXRX0   SPI_REG(SPI_TXRX0_OFFSET)
#define SPI_TXRX1   SPI_REG(SPI_TXRX1_OFFSET)
#define SPI_TXRX2   SPI_REG(SPI_TXRX2_OFFSET)
#define SPI_TXRX3   SPI_REG(SPI_TXRX3_OFFSET)
#define SPI_CTRL    SPI_REG(SPI_CTRL_OFFSET)
#define SPI_DIVIDER SPI_REG(SPI_DIVIDER_OFFSET)
#define SPI_SS      SPI_REG(SPI_SS_OFFSET)

/* ------------------------------------------------------------
 * CTRL 寄存器位定义
 * ------------------------------------------------------------ */
#define SPI_CTRL_ASS         (1u << 13)
#define SPI_CTRL_IE          (1u << 12)
#define SPI_CTRL_LSB         (1u << 11)
#define SPI_CTRL_TX_NEGEDGE  (1u << 10)
#define SPI_CTRL_RX_NEGEDGE  (1u << 9)
#define SPI_CTRL_GO          (1u << 8)

/* CHAR_LEN 位于 CTRL[6:0]。 */
#define SPI_CTRL_CHAR_LEN_MASK 0x7fu

#define SPI_SLAVE_COUNT        8u
#define SPI_MAX_TRANSFER_BITS 64u

static void spi_wait_done(void);

uint64_t spi_transfer64(const spi_transfer_config_t *config,
                        uint64_t                     transmit_data) {
  if (config == 0 || config->slave_select_index >= SPI_SLAVE_COUNT ||
      config->transfer_bit_count == 0u ||
      config->transfer_bit_count > SPI_MAX_TRANSFER_BITS) {
    return 0;
  }

  /* 必须在GO=0时写入发送数据和所有配置寄存器。 */
  SPI_TXRX0   = (uint32_t)transmit_data;
  SPI_TXRX1   = (uint32_t)(transmit_data >> 32);
  SPI_TXRX2   = 0u;
  SPI_TXRX3   = 0u;
  SPI_DIVIDER = config->clock_divider;
  SPI_SS      = 1u << config->slave_select_index;

  uint32_t control = config->transfer_bit_count & SPI_CTRL_CHAR_LEN_MASK;
  control |= SPI_CTRL_ASS;

  if (config->least_significant_bit_first) {
    control |= SPI_CTRL_LSB;
  }
  if (config->transmit_change_edge == SPI_CLOCK_EDGE_FALLING) {
    control |= SPI_CTRL_TX_NEGEDGE;
  }
  if (config->receive_sample_edge == SPI_CLOCK_EDGE_FALLING) {
    control |= SPI_CTRL_RX_NEGEDGE;
  }

  SPI_CTRL = control;
  SPI_CTRL = control | SPI_CTRL_GO;
  spi_wait_done();

  return ((uint64_t)SPI_TXRX1 << 32) | SPI_TXRX0;
}

/* bitrev 连接在 slave-select 7 上。 */
#define BITREV_SLAVE_SELECT (1u << 7)

/*
 * bitrev 使用一次 16-bit SPI 事务：
 *
 * 前 8 bit：
 *   master 通过 MOSI 发送输入数据。
 *
 * 后 8 bit：
 *   master 发送 dummy bit；
 *   bitrev 通过 MISO 返回反转后的结果。
 */
#define BITREV_TRANSFER_BITS 16u

/*
 * 软件参考位反转，用于测试 expected result。
 */
static uint8_t reverse8_sw(uint8_t value) {
  uint8_t result = 0;

  for (unsigned int bit = 0; bit < 8; bit++) {
    result |= ((value >> bit) & 1u) << (7u - bit);
  }

  return result;
}

/*
 * 初始化 SPI master。
 *
 * 当前约定：
 *   - SS 低电平有效；
 *   - MSB first，因此 LSB 位保持为 0；
 *   - bitrev 在 SCK 上升沿采样 MOSI；
 *   - bitrev 在 SCK 下降沿更新 MISO；
 *   - master 因而在下降沿更新 MOSI、上升沿采样 MISO；
 *   - 不使用中断，采用轮询；
 *   - 使用 ASS 自动控制 slave-select。
 */
void spi_init(void) {
  /*
   * SPI 时钟分频值。
   *
   * 具体 SCK 公式需要继续查看 spi_clgen.v。
   * 对仿真来说设置为一个较小非零值即可。
   */
  SPI_DIVIDER = 2u;

  /*
   * 选择 slave 7。
   *
   * SS 寄存器中置位对应 slave，SPI master 在外部引脚上
   * 通常会产生低有效的 spi_ss[7]。
   */
  SPI_SS = BITREV_SLAVE_SELECT;

  /*
   * 不在初始化阶段设置 GO。
   *
   * CHAR_LEN = 16：
   * 这个 OpenCores SPI core 中，CTRL[6:0] 直接表示传输位数；
   * SPI_MAX_CHAR=128 时，CHAR_LEN=0 通常有“128 位”的特殊含义，
   * 这里使用 16，不涉及该特殊情况。
   */
  uint32_t ctrl = 0;

  ctrl |= BITREV_TRANSFER_BITS & SPI_CTRL_CHAR_LEN_MASK;

  /*
   * TX_NEGEDGE = 1：
   * master 在下降沿更新 MOSI，使 MOSI 在下一个上升沿前稳定。
   *
   * RX_NEGEDGE = 0：
   * master 在上升沿采样 MISO。
   */
  ctrl |= SPI_CTRL_TX_NEGEDGE;

  /*
   * ASS = 1：
   * GO 启动后由硬件自动拉低选中的 SS；
   * 传输完成后自动释放 SS。
   */
  ctrl |= SPI_CTRL_ASS;

  /*
   * 下列位保持为 0：
   *
   * IE  = 0：不使用中断；
   * LSB = 0：MSB first；
   * RX_NEGEDGE = 0：上升沿采样。
   */
  SPI_CTRL = ctrl;
}

/*
 * 等待当前 SPI 事务完成。
 *
 * GO 位在传输过程中保持为 1，完成后由硬件清零。
 */
static void spi_wait_done(void) {
  while ((SPI_CTRL & SPI_CTRL_GO) != 0u) {
    /* Busy waiting。 */
  }
}

/*
 * 通过 SPI 调用 bitrev slave。
 *
 * 输入：
 *   input：需要进行位反转的 8 位数据。
 *
 * 返回：
 *   bitrev 通过 MISO 返回的 8 位结果。
 */
uint8_t spi_bitrev(uint8_t input) {
  /*
   * 16-bit MOSI 数据：
   *
   *   bit[15:8]：真实输入；
   *   bit[7:0] ：dummy 数据。
   *
   * 在 MSB-first 模式下，先发送 bit[15]，因此 input 应放在高 8 位。
   */
  const uint16_t tx_word =
      ((uint16_t)input << 8) |
      0x00ffu;

  /*
   * SPI_MAX_CHAR=128，但本次只传 16 bit，因此使用 TX0/RX0。
   *
   * 其余 TX 寄存器清零不是必须的，但可以避免旧值干扰调试。
   */
  SPI_TXRX1 = 0u;
  SPI_TXRX2 = 0u;
  SPI_TXRX3 = 0u;
  SPI_TXRX0 = (uint32_t)tx_word;

  /*
   * 保留原有配置，只将 GO 位置 1，启动事务。
   */
  SPI_CTRL = SPI_CTRL | SPI_CTRL_GO;

  spi_wait_done();

  /*
   * 同一个地址写时是 TX0，读时是 RX0。
   *
   * 16 个接收 bit 的预期组织为：
   *
   *   RX[15:8]：bitrev 接收输入期间的无效数据；
   *   RX[7:0] ：bitrev 后 8 拍返回的有效数据。
   */
  const uint32_t rx_word = SPI_TXRX0;

  return (uint8_t)(rx_word & 0xffu);
}

/*
 * 可选的自测试函数。
 *
 * 返回 0 表示成功；返回非零表示失败。
 */
int spi_bitrev_self_test(void) {
  static const uint8_t test_vectors[] = {
      0x00u,
      0x01u,
      0x80u,
      0x55u,
      0xaau,
      0xd2u,
      0xffu,
  };

  spi_init();

  for (unsigned int index = 0;
       index < sizeof(test_vectors) / sizeof(test_vectors[0]);
       index++) {
    const uint8_t input = test_vectors[index];
    const uint8_t expected = reverse8_sw(input);
    const uint8_t actual = spi_bitrev(input);

    if (actual != expected) {
      return (int)index + 1;
    }
  }

  return 0;
}
