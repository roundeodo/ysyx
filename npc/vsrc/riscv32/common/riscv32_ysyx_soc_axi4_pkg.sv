// ysyxSoC CPU插槽的固定AXI4类型。
//
// 这些类型只允许出现在system integration边界。core、cache和standalone memory
// 必须继续使用riscv32_axi4_pkg中的MEM_AXI_*类型，不能被课程SoC的32位数据口限制。
package riscv32_ysyx_soc_axi4_pkg;

  import riscv_config_pkg::*;
  import riscv32_axi4_pkg::axi4_burst_e;
  import riscv32_axi4_pkg::axi4_resp_e;

  typedef logic [YSYX_SOC_AXI_ADDR_WIDTH-1:0] ysyx_soc_axi4_addr_t;
  typedef logic [YSYX_SOC_AXI_DATA_WIDTH-1:0] ysyx_soc_axi4_data_t;
  typedef logic [YSYX_SOC_AXI_DATA_BYTE_COUNT-1:0] ysyx_soc_axi4_strb_t;
  typedef logic [YSYX_SOC_AXI_ID_WIDTH-1:0] ysyx_soc_axi4_id_t;

  typedef struct packed {
    ysyx_soc_axi4_addr_t addr;
    ysyx_soc_axi4_id_t   id;
    logic [7:0]          len;
    logic [2:0]          size;
    axi4_burst_e         burst;
  } ysyx_soc_axi4_write_address_t;

  typedef struct packed {
    ysyx_soc_axi4_data_t data;
    ysyx_soc_axi4_strb_t strb;
    logic                last;
  } ysyx_soc_axi4_write_data_t;

  typedef struct packed {
    ysyx_soc_axi4_id_t id;
    axi4_resp_e        resp;
  } ysyx_soc_axi4_write_response_t;

  typedef struct packed {
    ysyx_soc_axi4_addr_t addr;
    ysyx_soc_axi4_id_t   id;
    logic [7:0]          len;
    logic [2:0]          size;
    axi4_burst_e         burst;
  } ysyx_soc_axi4_read_address_t;

  typedef struct packed {
    ysyx_soc_axi4_data_t data;
    ysyx_soc_axi4_id_t   id;
    axi4_resp_e          resp;
    logic                last;
  } ysyx_soc_axi4_read_data_t;

  typedef struct packed {
    ysyx_soc_axi4_write_address_t aw;
    logic                         aw_valid;
    ysyx_soc_axi4_write_data_t    w;
    logic                         w_valid;
    logic                         b_ready;
    ysyx_soc_axi4_read_address_t  ar;
    logic                         ar_valid;
    logic                         r_ready;
  } ysyx_soc_axi4_manager_to_target_t;

  typedef struct packed {
    logic                          aw_ready;
    logic                          w_ready;
    ysyx_soc_axi4_write_response_t b;
    logic                          b_valid;
    logic                          ar_ready;
    ysyx_soc_axi4_read_data_t      r;
    logic                          r_valid;
  } ysyx_soc_axi4_target_to_manager_t;

endpackage : riscv32_ysyx_soc_axi4_pkg
