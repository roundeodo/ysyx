module riscv32_lsu
  import riscv32_pkg::*;
(
    input logic clk_i,
    // TODO(P2-LSU-RESET): LSU 加入跨周期事务状态时，在这里增加 rst_ni。
    // P1 组合适配器阶段可以暂时不使用 reset；P2 的 state_q/request_q/result_q 必须复位。
    // input logic rst_ni,

    /* verilator lint_off UNUSEDSIGNAL */
    input  execute_result_t memory_result_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic            memory_valid_i,
    output logic            memory_ready_o,

    output writeback_result_t writeback_result_o,
    output logic              writeback_valid_o,
    input  logic              writeback_ready_i,

    // LSU owns memory access semantics; the memory slave owns storage side effects.
    output mem_req_t  dmem_req_o,
    output logic      dmem_req_valid_o,
    input  logic      dmem_req_ready_i,
    input  mem_resp_t dmem_resp_i,
    input  logic      dmem_resp_valid_i,
    output logic      dmem_resp_ready_o
);

  // TODO(P1-LSU-DPI): memory 端口连通后，在这里删除两个 DPI import。把当前已经算好的
  // memory_addr、store_wdata、store_wmask、cmd 和 size 装入 dmem_req_o；load 原始数据改读
  // dmem_resp_i.rdata。pmem_write 的副作用必须移动到 riscv32_sim_mem，并且只允许在
  // dmem_req_valid_i && dmem_req_ready_o 时发生一次，不能因下游 stall 重复写。
  import "DPI-C" function int pmem_read_data(
    input int raddr,
    input int len
  );
  import "DPI-C" function void pmem_write(
    input int  addr,
    input int  wdata,
    input byte wmask
  );

  // TODO(P2-LSU-STATE): P1 全回归后，在这里加入 LSU 自己的一事务状态机和保持寄存器：
  //   LSU_ACCEPT     : memory_ready_o=1，fire 时锁存 memory_result_i 到 request_q；
  //   LSU_SEND_REQ   : 保持 dmem_req_o/valid，直到 dmem_req_ready_i；
  //   LSU_WAIT_RESP  : 等待 load/store completion response；
  //   LSU_HOLD_RESULT: 保持 writeback_result_o/valid，直到 completion mux ready。
  // 建议定义 state_q/state_d、execute_result_t request_q/request_d、
  // writeback_result_t result_q/result_d，以及 dmem_req_fire/dmem_resp_fire/writeback_fire。
  // misaligned 或上游已带 exception 的请求不访问 memory，直接构造异常 result 并进入
  // HOLD_RESULT。状态必须局部放在 LSU；未来它会被 load queue/store queue/MSHR 扩展。
  //
  // 进入 P2 后，下面所有地址、size、store data 和 uop 引用都应来自 request_q，不能继续
  // 读取 memory_result_i；上游在 memory_ready_o=0 时可以保存或更换自己的组合输入。
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

  // TODO(P1-LSU-REQ): 删除 DPI 后，在这里生成 dmem_req_o，并重写 ready/valid：
  //   - dmem_req_valid_o 仅对合法且无既有异常的 load/store 拉高；
  //   - request payload 在 valid=1、ready=0 时必须稳定；
  //   - 对 P1 零等待 adapter，memory fire、dmem request fire、response fire 和
  //     writeback fire 应描述同一次事务；
  //   - 对本地 misaligned exception，不发送 dmem request，但仍产生一次 writeback。
  // 不要让 dmem_req_valid_o 依赖 dmem_req_ready_i。P2 用 request_q+状态机自然满足稳定性。
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

  // TODO(P1-LSU-STORE): dmem 通道完成后删除整个 always_ff。store 是否真正修改 memory
  // 属于 memory slave/adapter；LSU 只能发出一次带 wdata/wmask 的请求。
  always_ff @(posedge clk_i) begin
    if (memory_fire && is_store && !misaligned && !memory_result_i.uop.exception_valid) begin
      pmem_write(memory_result_i.memory_addr, store_wdata, byte'(store_wmask));
    end
  end

  // TODO(P1-LSU-LOAD): 删除 pmem_read_data 调用。raw_rdata 应来自有效的
  // dmem_resp_i.rdata；P2 中应先锁存 response，再使用 request_q 中的 offset/size 完成
  // byte/half/word 选择和符号扩展。收到 store response 时 rdata 字段无意义。
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

  // TODO(P2-LSU-RESULT): 状态机加入后，在这里用 request_q + 已保存的 mem_resp 构造
  // result_d，并让模块输出来自 result_q。HOLD_RESULT 遇到 writeback_ready_i=0 时，
  // writeback_result_o 和 writeback_valid_o 必须保持稳定。只有 response fire 或本地异常
  // 才能生成一个结果，防止 load/store 被重复完成。
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
