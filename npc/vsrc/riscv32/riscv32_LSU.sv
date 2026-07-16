module riscv32_LSU
  import riscv32_pkg::*;
#(
    parameter DATA_WIDTH = 32
) (
    // TODO(HP-LSU-1): 用 memory issue channel 替换 i_lsu_ex_result。
    // LSU 只能接收 fu_type==FU_LSU 的 memory uop/riscv32_agu result，不能继续作为全部指令的通路。
    // 请求至少携带 addr、store_data、cmd、size、unsigned、physical_rd、rob_idx、lq/sq_idx。
    // 端口使用 valid/ready/bits，load miss 或队列满时必须能反压 riscv32_issue_queue。
    // from EXU
    // LSU 消费 EXU 产生的结构化 memory uop/result。
    // 未来接 LSQ、store buffer、D-cache 时，top 不应该手工拆散这些字段。
    /* verilator lint_off UNUSEDSIGNAL */
    input ex_result_t i_lsu_ex_result,
    /* verilator lint_on UNUSEDSIGNAL */

    // to WBU
    // LSU completion 必须是结构化 record。
    // 未来 load miss、memory replay、ordering violation、precise exception
    // 都应该随 LSU result 一起进入 ROB/WB。
    output lsu_result_t o_lsu_result
);
  // ==========================================================================
  // LSU design boundary
  // ==========================================================================
  //
  // LSU 的长期定位不是“DPI memory wrapper”，而是 CPU 后端的 memory execution unit。
  // 当前 C2 可以继续调用 DPI memory，但接口语义应该按 memory request 来设计。
  //
  // 高性能 CPU 关联：
  //   未来 LSU 会连接 D-cache、store buffer、load/store queue、总线 adapter。
  //   如果现在只用 mem_ren/mem_wen 两根散线，后续很难表达 request type、
  //   size、sign-extension、wmask、misalign、exception metadata、memory ordering。
  //
  // LSU request 的长期字段：
  //   mem_cmd_t  : MEM_CMD_NONE / MEM_CMD_LOAD / MEM_CMD_STORE
  //   mem_size_t : MEM_SIZE_BYTE / MEM_SIZE_HALF / MEM_SIZE_WORD
  //   addr       : effective address
  //   store_data : store source data before shifting
  //   unsigned   : load sign/zero extension control
  //
  // 高性能 CPU 关联：
  //   mem_cmd_t 是未来 D-cache/LSQ request opcode 的雏形。
  //   mem_size_t 会被 LSQ、store buffer、cache bank select、write mask generation 使用。
  //   load-data formatting 属于 LSU/load pipeline，不能散落到 WBU。
  //   precise exception 必须携带到 commit/ROB，再由 commit 阶段统一更新 trap state。

  // ============================================================
  // DPI-C memory interface
  //
  // pmem_read_data:
  //   只给 LSU load 使用，会触发 mtrace READ
  //
  // pmem_write:
  //   只给 LSU store 使用，会触发 mtrace WRITE
  //
  // IFU 取指仍然应该调用 pmem_read，不走这里。
  // ============================================================

  // TODO(HP-LSU-2): 删除下面两个 DPI import，把它们迁移到 riscv32_sim_mem。
  // LSU 输出 dmem_req_valid_o/dmem_req_ready_i/dmem_req_o，并接收
  // dmem_resp_valid_i/dmem_resp_ready_o/dmem_resp_i。
  // 这样同一个 Core 可以连接 DPI memory、D-cache 或 SoC 总线而无需修改 LSU。
  import "DPI-C" function int pmem_read_data(
    input int raddr,
    input int len
  );

  import "DPI-C" function void pmem_write(
    input int  addr,
    input int  wdata,
    input byte wmask
  );

  logic [1:0] addr_offset;
  assign addr_offset = i_lsu_ex_result.alu_res[1:0];

  // Decode memory request properties once, then reuse them in store mask,
  // DPI access, and load formatting.
  //
  // 高性能 CPU 关联：
  //   未来 LSU 会先形成规范化 memory uop，再进入 LSQ / store buffer /
  //   D-cache pipeline。集中派生 is_load/is_store/size/misalign 可以避免
  //   多处重复 decode，也方便以后把 exception metadata 随 completion 送到 ROB。
  logic is_load;
  logic is_store;
  logic size_half;
  logic size_word;
  logic load_misalign;
  logic store_misalign;

  assign is_load = (i_lsu_ex_result.mem_cmd == MEM_CMD_LOAD);
  assign is_store = (i_lsu_ex_result.mem_cmd == MEM_CMD_STORE);
  assign size_half = (i_lsu_ex_result.mem_size == MEM_SIZE_HALF);
  assign size_word = (i_lsu_ex_result.mem_size == MEM_SIZE_WORD);

  // TODO(HP-LSU-3): 不要只用 misalign 信号静默禁止访存。
  // load_misalign/store_misalign 必须生成 completion.exception_valid、exception_cause 和 badaddr，
  // 由 ROB 在提交时触发精确异常；异常 memory uop 不得发送 dmem request。
  assign load_misalign = is_load && ((size_half && addr_offset[0]) || (size_word && |addr_offset));
  assign store_misalign = is_store && ((size_half && addr_offset[0]) || (size_word && |addr_offset));

  // ============================================================
  // 访存长度
  //
  // mem_size_t:
  //   MEM_SIZE_BYTE -> byte
  //   MEM_SIZE_HALF -> halfword
  //   MEM_SIZE_WORD -> word
  // ============================================================

  int load_len;

  always_comb begin
    case (i_lsu_ex_result.mem_size)
      MEM_SIZE_BYTE: load_len = 1;  // lb / lbu
      MEM_SIZE_HALF: load_len = 2;  // lh / lhu
      MEM_SIZE_WORD: load_len = 4;  // lw
      default:       load_len = 4;
    endcase
  end

  // ============================================================
  // Store data and byte mask generation
  //
  // sb:
  //   根据 addr[1:0] 写一个 byte
  //
  // sh:
  //   根据 addr[1] 写低半字或者高半字
  //   这里默认不支持非对齐 sh，比如 addr[1:0] = 01/11
  //
  // sw:
  //   写 4 bytes
  // ============================================================

  logic [DATA_WIDTH-1:0] lsu_ram_wdata;
  logic [3:0] lsu_ram_wmask;

  always_comb begin
    lsu_ram_wdata = 32'b0;
    lsu_ram_wmask = 4'b0000;

    if (is_store && !store_misalign) begin
      case (i_lsu_ex_result.mem_size)
        MEM_SIZE_BYTE: begin  // sb
          case (addr_offset)
            2'b00: begin
              lsu_ram_wmask = 4'b0001;
              lsu_ram_wdata = {24'b0, i_lsu_ex_result.store_data[7:0]};
            end

            2'b01: begin
              lsu_ram_wmask = 4'b0010;
              lsu_ram_wdata = {16'b0, i_lsu_ex_result.store_data[7:0], 8'b0};
            end

            2'b10: begin
              lsu_ram_wmask = 4'b0100;
              lsu_ram_wdata = {8'b0, i_lsu_ex_result.store_data[7:0], 16'b0};
            end

            2'b11: begin
              lsu_ram_wmask = 4'b1000;
              lsu_ram_wdata = {i_lsu_ex_result.store_data[7:0], 24'b0};
            end
          endcase
        end

        MEM_SIZE_HALF: begin  // sh
          case (addr_offset)
            2'b00: begin
              lsu_ram_wmask = 4'b0011;
              lsu_ram_wdata = {16'b0, i_lsu_ex_result.store_data[15:0]};
            end

            2'b10: begin
              lsu_ram_wmask = 4'b1100;
              lsu_ram_wdata = {i_lsu_ex_result.store_data[15:0], 16'b0};
            end

            default: begin
              // 当前简单 NPC 暂不支持非对齐 sh。
              lsu_ram_wmask = 4'b0000;
              lsu_ram_wdata = 32'b0;
            end
          endcase
        end

        MEM_SIZE_WORD: begin  // sw
          lsu_ram_wmask = 4'b1111;
          lsu_ram_wdata = i_lsu_ex_result.store_data;
        end

        default: begin
          lsu_ram_wmask = 4'b0000;
          lsu_ram_wdata = 32'b0;
        end
      endcase
    end
  end

  // ============================================================
  // DPI-C memory access
  //
  // 重要：
  //   load 时调用 pmem_read_data，会打印 mtrace READ
  //   store 时调用 pmem_write，会打印 mtrace WRITE
  //
  // 不要在 store 时额外 read，否则 mtrace 会出现假的 READ。
  // ============================================================

  logic [DATA_WIDTH-1:0] raw_rdata;

  // TODO(HP-LSU-4): 完成 HP-LSU-2 后删除下面整个组合 DPI access block。
  // 在这里改成 request 生成和 response 接收状态机/流水级：store 只有到 riscv32_commit 授权后
  // 才能真正写内存；推测执行的 load 可以提前读，但必须支持 miss、replay 和 flush 丢弃。
  always_comb begin
    raw_rdata = 32'b0;

    if (is_load && !load_misalign) begin
      raw_rdata = pmem_read_data(i_lsu_ex_result.alu_res, load_len);
    end

    // MEM_CMD_NONE 不调用 pmem_read_data，也不调用 pmem_write。
    // 这对 mtrace 很关键，不能为了 store mask generation 额外 read memory。
    if (is_store && !store_misalign) begin
      pmem_write(i_lsu_ex_result.alu_res, lsu_ram_wdata, byte'(lsu_ram_wmask));
    end
  end

  // ============================================================
  // Load data extraction
  //
  // raw_rdata 是对齐读出来的 32-bit word。
  // 这里根据 addr_offset 取 byte / halfword / word。
  // ============================================================

  logic [ 7:0] byte_rdata;
  logic [15:0] half_rdata;

  always_comb begin
    case (addr_offset)
      2'b00:   byte_rdata = raw_rdata[7:0];
      2'b01:   byte_rdata = raw_rdata[15:8];
      2'b10:   byte_rdata = raw_rdata[23:16];
      2'b11:   byte_rdata = raw_rdata[31:24];
      default: byte_rdata = 8'b0;
    endcase
  end

  always_comb begin
    case (addr_offset[1])
      1'b0:    half_rdata = raw_rdata[15:0];
      1'b1:    half_rdata = raw_rdata[31:16];
      default: half_rdata = 16'b0;
    endcase
  end

  logic [DATA_WIDTH-1:0] formatted_load_data;
  always_comb begin
    //   高性能 CPU 关联：
    //     load formatting 是 LSU 的结果生成逻辑。未来 load queue / bypass / ROB
    //     都应该看到已经格式化好的 load result。
    formatted_load_data = 32'b0;

    if (is_load && !load_misalign) begin
      case (i_lsu_ex_result.mem_size)
        MEM_SIZE_BYTE: begin  // lb / lbu
          if (i_lsu_ex_result.mem_unsigned) begin
            formatted_load_data = {24'b0, byte_rdata};
          end else begin
            formatted_load_data = {{24{byte_rdata[7]}}, byte_rdata};
          end
        end

        MEM_SIZE_HALF: begin  // lh / lhu
          if (i_lsu_ex_result.mem_unsigned) begin
            formatted_load_data = {16'b0, half_rdata};
          end else begin
            formatted_load_data = {{16{half_rdata[15]}}, half_rdata};
          end
        end

        MEM_SIZE_WORD: begin  // lw
          formatted_load_data = raw_rdata;
        end

        default: begin
          formatted_load_data = 32'b0;
        end
      endcase
    end
  end

  // ============================================================
  // pass through
  // ============================================================

  // LSU 输出的 completion record 是 WBU、bypass、ROB completion 的共同输入。
  // 当前单周期直接送 WBU；未来乱序实现中，load/store 完成后应写入 ROB/PRF
  // 或触发 replay/exception metadata 更新。
  // TODO(HP-LSU-5): 用 LSU completion channel 替换下面 o_lsu_result 打包块。
  // load response 格式化完成后输出最终 result；store 输出地址/数据已就绪状态给 ROB/SQ，
  // 不直接写 architectural RF。completion 必须携带 rob_idx/physical_rd/exception/replay。
  always_comb begin
    o_lsu_result           = '0;
    o_lsu_result.valid     = i_lsu_ex_result.valid;
    o_lsu_result.alu_res   = i_lsu_ex_result.alu_res;
    o_lsu_result.mem_rdata = formatted_load_data;
    o_lsu_result.pc_plus_4 = i_lsu_ex_result.pc_plus_4;
    o_lsu_result.rd_addr   = i_lsu_ex_result.rd_addr;
    o_lsu_result.wb_sel    = i_lsu_ex_result.wb_sel;
    o_lsu_result.reg_wen   = i_lsu_ex_result.reg_wen;
  end

endmodule
