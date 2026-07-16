module riscv32_lsu
  import riscv32_pkg::*;
(
    input logic clk_i,

    /* verilator lint_off UNUSEDSIGNAL */
    input  execute_result_t memory_result_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic            memory_valid_i,
    output logic            memory_ready_o,

    output writeback_result_t writeback_result_o,
    output logic              writeback_valid_o,
    input  logic              writeback_ready_i
);
  // NOTE(P1): move both DPI calls into riscv32_sim_mem and expose a typed dmem
  // request/response channel. LSU memory semantics remain unchanged by that move.
  import "DPI-C" function int pmem_read_data(
    input int raddr,
    input int len
  );
  import "DPI-C" function void pmem_write(
    input int  addr,
    input int  wdata,
    input byte wmask
  );

  logic [           1:0] addr_offset;
  logic                  is_load;
  logic                  is_store;
  logic                  size_half;
  logic                  size_word;
  logic                  misaligned;
  logic                  memory_fire;
  int                    load_len;

  logic [      XLEN-1:0] raw_rdata;
  logic [           7:0] byte_rdata;
  logic [          15:0] half_rdata;
  logic [      XLEN-1:0] formatted_load_data;
  logic [      XLEN-1:0] store_wdata;
  logic [BYTE_LANES-1:0] store_wmask;

  assign addr_offset       = memory_result_i.memory_addr[1:0];
  assign is_load           = memory_result_i.uop.mem_ctrl.cmd == MEM_CMD_LOAD;
  assign is_store          = memory_result_i.uop.mem_ctrl.cmd == MEM_CMD_STORE;
  assign size_half         = memory_result_i.uop.mem_ctrl.size == MEM_SIZE_HALF;
  assign size_word         = memory_result_i.uop.mem_ctrl.size == MEM_SIZE_WORD;
  assign misaligned        = (size_half && addr_offset[0]) || (size_word && (addr_offset != 2'b00));

  assign memory_ready_o    = writeback_ready_i;
  assign writeback_valid_o = memory_valid_i;
  assign memory_fire       = memory_valid_i && memory_ready_o;

  always_comb begin
    unique case (memory_result_i.uop.mem_ctrl.size)
      MEM_SIZE_BYTE: load_len = 1;
      MEM_SIZE_HALF: load_len = 2;
      default:       load_len = 4;
    endcase
  end

  always_comb begin
    store_wdata = '0;
    store_wmask = '0;

    unique case (memory_result_i.uop.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        store_wmask = 4'b0001 << addr_offset;
        store_wdata = {24'b0, memory_result_i.memory_wdata[7:0]} << (8 * addr_offset);
      end
      MEM_SIZE_HALF: begin
        store_wmask = 4'b0011 << addr_offset;
        store_wdata = {16'b0, memory_result_i.memory_wdata[15:0]} << (8 * addr_offset);
      end
      MEM_SIZE_WORD: begin
        store_wmask = 4'b1111;
        store_wdata = memory_result_i.memory_wdata;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (memory_fire && is_store && !misaligned && !memory_result_i.uop.exception_valid) begin
      pmem_write(memory_result_i.memory_addr, store_wdata, byte'(store_wmask));
    end
  end

  always_comb begin
    raw_rdata = '0;
    if (memory_valid_i && is_load && !misaligned && !memory_result_i.uop.exception_valid) begin
      raw_rdata = pmem_read_data(memory_result_i.memory_addr, load_len);
    end
  end

  always_comb begin
    unique case (addr_offset)
      2'b00:   byte_rdata = raw_rdata[7:0];
      2'b01:   byte_rdata = raw_rdata[15:8];
      2'b10:   byte_rdata = raw_rdata[23:16];
      default: byte_rdata = raw_rdata[31:24];
    endcase

    half_rdata = addr_offset[1] ? raw_rdata[31:16] : raw_rdata[15:0];
  end

  always_comb begin
    unique case (memory_result_i.uop.mem_ctrl.size)
      MEM_SIZE_BYTE: begin
        formatted_load_data = memory_result_i.uop.mem_ctrl.unsigned_load ?
                              {24'b0, byte_rdata} :
                              {{24{byte_rdata[7]}}, byte_rdata};
      end
      MEM_SIZE_HALF: begin
        formatted_load_data = memory_result_i.uop.mem_ctrl.unsigned_load ?
                              {16'b0, half_rdata} :
                              {{16{half_rdata[15]}}, half_rdata};
      end
      default: formatted_load_data = raw_rdata;
    endcase
  end

  always_comb begin
    writeback_result_o              = '0;
    writeback_result_o.uop          = memory_result_i.uop;
    writeback_result_o.result       = is_load ? formatted_load_data : memory_result_i.result;
    writeback_result_o.next_pc      = memory_result_i.next_pc;
    writeback_result_o.csr_wdata    = memory_result_i.csr_wdata;
    writeback_result_o.memory_addr  = memory_result_i.memory_addr;
    writeback_result_o.memory_rdata = is_load ? formatted_load_data : '0;
    writeback_result_o.memory_wdata = store_wdata;
    writeback_result_o.memory_wmask = is_store ? store_wmask : '0;

    if (misaligned) begin
      writeback_result_o.uop.exception_valid = 1'b1;
      writeback_result_o.uop.exception_cause = is_load ?
                                                EXC_LOAD_ADDR_MISALIGNED :
                                                EXC_STORE_ADDR_MISALIGNED;
      writeback_result_o.uop.exception_tval = memory_result_i.memory_addr;
    end
  end

  // NOTE(P5): add the LSQ, store buffer, replay, and cache interface here.
  // Stores must then become externally visible only after commit authorization.

endmodule
