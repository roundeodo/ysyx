// TODO(AXI-MEM-MODULE): 本模块要从SimpleBus slave重写为两套AXI4-Lite slave：
// 1. imem read-only slave，只含AR/R。
// 2. dmem read/write slave，含AR/R/AW/W/B。
// DPI仍只存在于该仿真adapter中。不要在IFU/LSU加入pmem_read/pmem_write。
//
// 第一版每个方向只允许一个outstanding事务，但imem read、dmem read和dmem write应使用
// 独立状态/缓冲，不能继续共用一个dmem req状态机。这样既符合通道独立性，也为以后接
// dual-port SRAM、I-cache/D-cache或interconnect保留清晰边界。
//
// Simulation-only SimpleBus memory slave. DPI remains only in this outer adapter so
// the core can keep using the existing C++ image, MMIO, trace, and DiffTest backend.
module riscv32_sim_mem
  import riscv32_pkg::*;
#(
    parameter int unsigned IMEM_RESPONSE_LATENCY = 1,
    parameter int unsigned DMEM_RESPONSE_LATENCY = 1
) (
    input logic clk_i,
    input logic rst_ni,

    // TODO(AXI-MEM-PORTS): 删除下面SimpleBus端口并按slave方向声明AXI端口。
    // ifu_axi：输入AR payload/ARVALID，输出ARREADY；输出R payload/RVALID，输入RREADY。
    // lsu_axi read：输入AR payload/ARVALID，输出ARREADY；输出R payload/RVALID，输入RREADY。
    // lsu_axi write：输入AW/W payload和VALID，分别输出AWREADY/WREADY；输出B payload/BVALID，
    // 输入BREADY。AW与W端口不能合并，因为协议允许它们任意先后握手。
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

  // TODO(AXI-MEM-LATENCY): 将延迟参数拆成IMEM_READ、DMEM_READ和DMEM_WRITE三类。
  // 计数从对应请求完整接收开始：read从AR握手开始；write必须等AW和W都握手后才开始。
  // 延迟结束后拉高RVALID/BVALID，并在READY到来前保持响应。反压只能延长响应保持时间，
  // 不能重新执行DPI访问，也不能重新启动延迟计数。
  //
  // Each port accepts one outstanding transaction. Response latency counts from the
  // request handshake cycle; latency=1 preserves the original next-cycle response.
  // The registered response payload remains stable until its response handshake.

  localparam int unsigned IMEM_DELAY_W = (IMEM_RESPONSE_LATENCY > 1) ? $clog2(
      IMEM_RESPONSE_LATENCY
  ) : 1;
  localparam int unsigned DMEM_DELAY_W = (DMEM_RESPONSE_LATENCY > 1) ? $clog2(
      DMEM_RESPONSE_LATENCY
  ) : 1;

  // TODO(AXI-MEM-STATE): 删除这个同时用于imem/dmem的通用SimpleBus状态定义，分别建立：
  // - imem read状态和地址寄存器；
  // - dmem read状态和地址寄存器；
  // - dmem write收集状态、AW地址寄存器、W数据/strb寄存器、aw_seen_q和w_seen_q。
  //
  // write slave必须能处理四种情况：AW先到、W先到、同拍到、二者都长期反压。
  // AWREADY只表示有空间保存一个地址，WREADY只表示有空间保存一个数据；任何一个channel
  // 的READY都不应以另一个channel先握手为前提。BVALID只能在本事务AW和W都收到后产生。
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

  // TODO(AXI-MEM-HANDSHAKE): 将四个SimpleBus握手替换为imem AR/R以及dmem
  // AR/R/AW/W/B共7个握手事件。slave可以等待VALID再拉READY，但为获得单拍接收性能，
  // 空闲且buffer有空间时应提前拉高READY。RVALID/BVALID不得等待RREADY/BREADY才产生。
  //
  // A transfer occurs only when both sides complete the valid/ready handshake.
  assign imem_req_handshake  = imem_req_valid_i && imem_req_ready_o;
  assign imem_resp_handshake = imem_resp_valid_o && imem_resp_ready_i;
  assign dmem_req_handshake  = dmem_req_valid_i && dmem_req_ready_o;
  assign dmem_resp_handshake = dmem_resp_valid_o && dmem_resp_ready_i;

  initial begin
    if (IMEM_RESPONSE_LATENCY == 0) $fatal(1, "IMEM_RESPONSE_LATENCY must be >= 1");
    if (DMEM_RESPONSE_LATENCY == 0) $fatal(1, "DMEM_RESPONSE_LATENCY must be >= 1");
  end

  // TODO(AXI-MEM-DPI-SIZE): AXI4-Lite没有AxSIZE，完成迁移后删除mem_size_to_bytes。
  // 所有read都调用pmem_read(addr_aligned)或等价的4-byte读取，返回完整32-bit RDATA。
  // store调用pmem_write(AWADDR, WDATA, WSTRB)，memory slave必须完整支持WSTRB。
  // DPI调用必须由“新事务完成接收”的单周期事件触发一次，不能放在RVALID/BVALID保持块中，
  // 否则response反压会重复读取MMIO或重复写设备。
  //
  // Convert the protocol encoding into the byte count required by the DPI backend.
  function automatic int mem_size_to_bytes(input mem_size_e size);
    unique case (size)
      MEM_SIZE_BYTE: mem_size_to_bytes = 1;
      MEM_SIZE_HALF: mem_size_to_bytes = 2;
      MEM_SIZE_WORD: mem_size_to_bytes = 4;
      default:       mem_size_to_bytes = 4;
    endcase
  endfunction


  // TODO(AXI-MEM-IMEM-READ): 用标准AR/R slave重写下面三个imem block。
  // ARREADY在没有未完成imem read时为1；AR握手时保存ARADDR并只执行一次pmem_read。
  // 延迟到期后设置RDATA和RRESP=OKAY并拉高RVALID。若地址decode失败，则不读后端，
  // 返回DECERR；若slave内部执行失败则返回SLVERR。RVALID && !RREADY时RDATA/RRESP稳定。
  // R握手后才允许该单outstanding slot重新接收下一条AR。
  //
  // 高效版本可增加1-entry AR skid buffer，使R通道保持响应时还能预收下一地址，但第一次
  // 实现不要同时提高outstanding深度；先保证每个AR恰好对应一个R。
  //
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


  // TODO(AXI-MEM-DMEM-READ): dmem read使用独立AR/R状态，不再从cmd判断load。
  // 行为与imem read相同，但地址范围错误返回DECERR。对MMIO read要在AR事务被接受后只执行
  // 一次，不能因为RREADY低而重复产生读取副作用。
  //
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

  // TODO(AXI-MEM-DMEM-WRITE): 删除下面按dmem_req_handshake执行load/store的块，改为：
  // 1. AW握手时保存AWADDR/AWPROT并置aw_seen_q。
  // 2. W握手时保存WDATA/WSTRB并置w_seen_q。
  // 3. 当旧seen或本拍handshake表明两者均已收到时，只执行一次pmem_write。
  // 4. 写延迟到期后产生BRESP和BVALID；BVALID && !BREADY期间保持不变。
  // 5. B握手后清seen并允许下一事务。
  //
  // 第3步必须能从寄存器或本拍握手payload中选择正确值，覆盖AW/W同拍到达和任意先后到达。
  // 不要用AWADDR当前输入配对以前保存的W，也不要在只收到一个channel时执行写入。
  // 地址decode失败返回DECERR，写保护/后端错误返回SLVERR；即使错误也必须产生B响应，防止
  // master永久等待。
  //
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

  // TODO(AXI-MEM-CONCURRENCY): 当前CPU的单条LSU操作不会同时发load和store，但IFU取指可与
  // LSU数据访问并行。仿真DPI后端允许这种逻辑并行；若以后映射到单端口SRAM，需要在本模块
  // 内或独立adapter中仲裁实际backend access，同时保持已经接受的AXI事务不会丢失。
  //
  // 同地址同周期读写的返回值由具体memory实现决定，不能假设所有SRAM/FPGA BRAM一致。
  // 若系统需要确定行为，应在backend仲裁中明确read-first、write-first或禁止并发，并通过
  // assertion检查。该策略不属于AXI握手协议本身。
  //
  // TODO(AXI-MEM-ASSERT): slave侧加入协议断言：
  // - reset期间RVALID/BVALID为0。
  // - RVALID && !RREADY时RDATA/RRESP稳定；BVALID && !BREADY时BRESP稳定。
  // - 每个R之前恰好有一个AR；每个B之前恰好有一个AW和一个W。
  // - AW/W可按任意顺序握手，且一次事务不能重复接收第二个AW或W。
  // - READY/VALID逻辑不存在AXI输入到AXI输出的组合路径。



endmodule
