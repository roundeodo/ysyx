// Simulation-only SimpleBus memory slave. DPI remains only in this outer adapter so
// the core can keep using the existing C++ image, MMIO, trace, and DiffTest backend.
module riscv32_sim_mem
  import riscv32_pkg::*;
#(
    parameter int unsigned IMEM_RESPONSE_LATENCY = 1,
    parameter int unsigned DMEM_RESPONSE_LATENCY = 1
) 
(
    input logic clk_i,
    input logic rst_ni,

    input  imem_req_t  imem_req_i,
    input  logic       imem_req_valid_i,
    output logic       imem_req_ready_o,
    output imem_resp_t imem_resp_o,
    output logic       imem_resp_valid_o,
    input  logic       imem_resp_ready_i,

    input  mem_req_t  dmem_req_i,
    input  logic      dmem_req_valid_i,
    output logic      dmem_req_ready_o,
    output mem_resp_t dmem_resp_o,
    output logic      dmem_resp_valid_o,
    input  logic      dmem_resp_ready_i
);

  // DPI 允许存在于本 simulation adapter，但禁止出现在 riscv32_core/IFU/LSU 中。
  // 这与手册的 SimpleBus 示例一致：pmem_read/pmem_write 仍可作为仿真 memory 的
  // 数据和设备后端，只是调用被移动到 memory slave，并通过时序逻辑产生读延迟。、
  import "DPI-C" function int pmem_read(input int raddr);
  import "DPI-C" function int pmem_read_data(
    input int raddr,
    input int len
  );
  import "DPI-C" function void pmem_write(
    input int  addr,
    input int  wdata,
    input byte wmask
  );

  // Each port accepts one outstanding transaction. Response latency counts from the
  // request handshake cycle; latency=1 preserves the original next-cycle response.
  // The registered response payload remains stable until its response handshake.

  localparam int unsigned IMEM_DELAY_W =
      (IMEM_RESPONSE_LATENCY > 1) ? $clog2(IMEM_RESPONSE_LATENCY) : 1;
  localparam int unsigned DMEM_DELAY_W =
      (DMEM_RESPONSE_LATENCY > 1) ? $clog2(DMEM_RESPONSE_LATENCY) : 1;

  typedef enum logic [1:0] {
    MEM_IDLE,
    MEM_WAIT_RESP,
    MEM_RESPOND,
    MEM_HOLD_RESP
  } mem_state_e;

  mem_state_e imem_state_q;
  mem_state_e imem_state_d;
  mem_state_e dmem_state_q;
  mem_state_e dmem_state_d;

  imem_resp_t imem_resp_q;
  mem_resp_t dmem_resp_q;

  logic [IMEM_DELAY_W-1:0] imem_delay_q;
  logic [IMEM_DELAY_W-1:0] imem_delay_d;
  logic [DMEM_DELAY_W-1:0] dmem_delay_q;
  logic [DMEM_DELAY_W-1:0] dmem_delay_d;

  logic imem_req_handshake;
  logic dmem_req_handshake;
  logic imem_resp_handshake;
  logic dmem_resp_handshake;

  // A transfer occurs only when both sides complete the valid/ready handshake.
  assign imem_req_handshake  = imem_req_valid_i && imem_req_ready_o;
  assign imem_resp_handshake = imem_resp_valid_o && imem_resp_ready_i;
  assign dmem_req_handshake  = dmem_req_valid_i && dmem_req_ready_o;
  assign dmem_resp_handshake = dmem_resp_valid_o && dmem_resp_ready_i;

  initial begin
    if (IMEM_RESPONSE_LATENCY == 0) $fatal(1, "IMEM_RESPONSE_LATENCY must be >= 1");
    if (DMEM_RESPONSE_LATENCY == 0) $fatal(1, "DMEM_RESPONSE_LATENCY must be >= 1");
  end

  // Convert the protocol encoding into the byte count required by the DPI backend.
  function automatic int mem_size_to_bytes(input mem_size_e size);
    unique case (size)
      MEM_SIZE_BYTE: mem_size_to_bytes = 1;
      MEM_SIZE_HALF: mem_size_to_bytes = 2;
      MEM_SIZE_WORD: mem_size_to_bytes = 4;
      default:       mem_size_to_bytes = 4;
    endcase
  endfunction

  // State register and instruction-response storage.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      imem_state_q <= MEM_IDLE;
      imem_delay_q <= '0;
      imem_resp_q  <= '0;
    end else begin
      imem_state_q <= imem_state_d;
      imem_delay_q <= imem_delay_d;
      if (imem_req_handshake) begin
        imem_resp_q.txn_id          <= imem_req_i.txn_id;
        imem_resp_q.instruction     <= pmem_read(imem_req_i.addr);
        imem_resp_q.exception_valid <= 1'b0;
        imem_resp_q.exception_cause <= exception_cause_e'('0);
        imem_resp_q.exception_tval  <= '0;
      end
    end
  end

  // Next-state logic.
  always_comb begin
    imem_state_d = imem_state_q;
    imem_delay_d = imem_delay_q;

    unique case (imem_state_q)
      MEM_IDLE: begin
        if (imem_req_handshake) begin
          if (IMEM_RESPONSE_LATENCY == 1) begin
            imem_state_d = MEM_RESPOND;
          end else begin
            imem_delay_d = IMEM_DELAY_W'(IMEM_RESPONSE_LATENCY - 1);
            imem_state_d = MEM_WAIT_RESP;
          end
        end
      end
      MEM_WAIT_RESP: begin
        if (imem_delay_q == IMEM_DELAY_W'(1)) begin
          imem_delay_d = '0;
          imem_state_d = MEM_RESPOND;
        end else begin
          imem_delay_d = imem_delay_q - IMEM_DELAY_W'(1);
        end
      end
      MEM_RESPOND: begin
        if (imem_resp_handshake) imem_state_d = MEM_IDLE;
        else imem_state_d = MEM_HOLD_RESP;
      end
      MEM_HOLD_RESP: begin
        if (imem_resp_handshake) imem_state_d = MEM_IDLE;
      end
      default: begin
        imem_state_d = MEM_IDLE;
        imem_delay_d = '0;
      end
    endcase
  end

  // Moore output logic.
  always_comb begin
    imem_req_ready_o  = 1'b0;
    imem_resp_valid_o = 1'b0;
    imem_resp_o       = imem_resp_q;
    unique case (imem_state_q)
      MEM_IDLE:      imem_req_ready_o = 1'b1;
      MEM_RESPOND:   imem_resp_valid_o = 1'b1;
      MEM_HOLD_RESP: imem_resp_valid_o = 1'b1;
      default:       ;
    endcase
  end
  // State register and data-response storage.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dmem_state_q <= MEM_IDLE;
      dmem_delay_q <= '0;
      dmem_resp_q  <= '0;
    end else begin
      dmem_state_q <= dmem_state_d;
      dmem_delay_q <= dmem_delay_d;
      if (dmem_req_handshake) begin
        dmem_resp_q.txn_id          <= dmem_req_i.txn_id;
        dmem_resp_q.exception_valid <= 1'b0;
        dmem_resp_q.exception_cause <= exception_cause_e'('0);
        dmem_resp_q.exception_tval  <= '0;

        unique case (dmem_req_i.cmd)
          MEM_CMD_LOAD: begin
            dmem_resp_q.rdata <=
                pmem_read_data(dmem_req_i.addr, mem_size_to_bytes(dmem_req_i.size));
          end
          MEM_CMD_STORE: begin
            pmem_write(dmem_req_i.addr, dmem_req_i.wdata, byte'(dmem_req_i.wmask));
            dmem_resp_q.rdata <= '0;
          end
          default: begin
            // MEM_CMD_NONE不访问后端，但仍生成一个响应，避免状态机停在MEM_HOLD_RESP。
            dmem_resp_q.rdata <= '0;
          end
        endcase
      end
    end
  end

  // Next state logic
  always_comb begin
    dmem_state_d = dmem_state_q;
    dmem_delay_d = dmem_delay_q;

    unique case (dmem_state_q)
      MEM_IDLE: begin
        if (dmem_req_handshake) begin
          if (DMEM_RESPONSE_LATENCY == 1) begin
            dmem_state_d = MEM_RESPOND;
          end else begin
            dmem_delay_d = DMEM_DELAY_W'(DMEM_RESPONSE_LATENCY - 1);
            dmem_state_d = MEM_WAIT_RESP;
          end
        end
      end
      MEM_WAIT_RESP: begin
        if (dmem_delay_q == DMEM_DELAY_W'(1)) begin
          dmem_delay_d = '0;
          dmem_state_d = MEM_RESPOND;
        end else begin
          dmem_delay_d = dmem_delay_q - DMEM_DELAY_W'(1);
        end
      end
      MEM_RESPOND: begin
        if (dmem_resp_handshake) dmem_state_d = MEM_IDLE;
        else dmem_state_d = MEM_HOLD_RESP;
      end
      MEM_HOLD_RESP: begin
        if (dmem_resp_handshake) dmem_state_d = MEM_IDLE;
      end
      default: begin
        dmem_state_d = MEM_IDLE;
        dmem_delay_d = '0;
      end
    endcase
  end

  // Moore output logic.
  always_comb begin
    dmem_req_ready_o  = 1'b0;
    dmem_resp_valid_o = 1'b0;
    dmem_resp_o       = dmem_resp_q;

    unique case (dmem_state_q)
      MEM_IDLE:      dmem_req_ready_o = 1'b1;
      MEM_RESPOND:   dmem_resp_valid_o = 1'b1;
      MEM_HOLD_RESP: dmem_resp_valid_o = 1'b1;
      default:       ;
    endcase
  end

endmodule
