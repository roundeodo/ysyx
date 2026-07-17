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
    // TODO(AXI-MEM-PARAM-CODE): 用三类独立延迟替换当前两个参数，并同步修改top实例参数名。
    parameter int unsigned IFU_READ_LATENCY  = 1,
    parameter int unsigned LSU_READ_LATENCY  = 1,
    parameter int unsigned LSU_WRITE_LATENCY = 1
) (
    input logic clk_i,
    input logic rst_ni,

    // TODO(AXI-MEM-PORTS): 删除下面SimpleBus端口并按slave方向声明AXI端口。
    // ifu_axi：输入AR payload/ARVALID，输出ARREADY；输出R payload/RVALID，输入RREADY。
    // lsu_axi read：输入AR payload/ARVALID，输出ARREADY；输出R payload/RVALID，输入RREADY。
    // lsu_axi write：输入AW/W payload和VALID，分别输出AWREADY/WREADY；输出B payload/BVALID，
    // 输入BREADY。AW与W端口不能合并，因为协议允许它们任意先后握手。
    //
    // TODO(AXI-MEM-PORT-CODE): 删除下面全部SimpleBus端口，换成以下slave端口：
    input  axi_lite_addr_t ifu_axi_ar_i,
    input  logic           ifu_axi_arvalid_i,
    output logic           ifu_axi_arready_o,
    output axi_lite_r_t    ifu_axi_r_o,
    output logic           ifu_axi_rvalid_o,
    input  logic           ifu_axi_rready_i,

    input  axi_lite_addr_t lsu_axi_ar_i,
    input  logic           lsu_axi_arvalid_i,
    output logic           lsu_axi_arready_o,
    output axi_lite_r_t    lsu_axi_r_o,
    output logic           lsu_axi_rvalid_o,
    input  logic           lsu_axi_rready_i,

    input  axi_lite_addr_t lsu_axi_aw_i,
    input  logic           lsu_axi_awvalid_i,
    output logic           lsu_axi_awready_o,
    input  axi_lite_w_t    lsu_axi_w_i,
    input  logic           lsu_axi_wvalid_i,
    output logic           lsu_axi_wready_o,
    output axi_lite_b_t    lsu_axi_b_o,
    output logic           lsu_axi_bvalid_o,
    input  logic           lsu_axi_bready_i
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
  //
  // TODO(AXI-MEM-DECL-CODE): 删除下面旧localparam、mem_state_e及全部旧状态/响应声明，
  // 改为以下三套独立事务状态。RESP状态自身保持VALID，不再需要单独HOLD状态：
  //
  localparam int unsigned IFU_DELAY_W = (IFU_READ_LATENCY > 1) ? $clog2(IFU_READ_LATENCY) : 1;
  localparam int unsigned LSU_READ_DELAY_W = (LSU_READ_LATENCY > 1) ? $clog2(LSU_READ_LATENCY) : 1;
  localparam int unsigned LSU_WRITE_DELAY_W = (LSU_WRITE_LATENCY > 1) ? $clog2(
      LSU_WRITE_LATENCY
  ) : 1;
  //
  typedef enum logic [1:0] {
    READ_IDLE,
    READ_WAIT,
    READ_RESP
  } read_state_e;
  //
  typedef enum logic [1:0] {
    WRITE_COLLECT,
    WRITE_WAIT,
    WRITE_RESP
  } write_state_e;
  //
  read_state_e ifu_read_state_q, ifu_read_state_d;
  read_state_e lsu_read_state_q, lsu_read_state_d;
  write_state_e lsu_write_state_q, lsu_write_state_d;
  //
  axi_lite_r_t ifu_r_q;
  axi_lite_r_t lsu_r_q;
  axi_lite_b_t lsu_b_q;
  //
  axi_lite_addr_t lsu_aw_q, lsu_aw_d;
  axi_lite_w_t lsu_w_q, lsu_w_d;
  axi_lite_addr_t active_lsu_aw;
  axi_lite_w_t    active_lsu_w;
  //
  logic [IFU_DELAY_W-1:0] ifu_delay_q, ifu_delay_d;
  logic [LSU_READ_DELAY_W-1:0] lsu_read_delay_q, lsu_read_delay_d;
  logic [LSU_WRITE_DELAY_W-1:0] lsu_write_delay_q, lsu_write_delay_d;
  //
  logic lsu_aw_handshake_occurred_q, lsu_aw_handshake_occurred_d;
  logic lsu_w_handshake_occurred_q, lsu_w_handshake_occurred_d;
  //
  logic ifu_ar_handshake, ifu_r_handshake;
  logic lsu_ar_handshake, lsu_r_handshake;
  logic lsu_aw_handshake, lsu_w_handshake, lsu_b_handshake;
  logic lsu_write_request_complete;

  // TODO(AXI-MEM-STATE): 删除这个同时用于imem/dmem的通用SimpleBus状态定义，分别建立：
  // - imem read状态和地址寄存器；
  // - dmem read状态和地址寄存器；
  // - dmem write收集状态、AW/W暂存寄存器及其valid状态。
  //
  // write slave必须能处理四种情况：AW先到、W先到、同拍到、二者都长期反压。
  // AWREADY只表示有空间保存一个地址，WREADY只表示有空间保存一个数据；任何一个channel
  // 的READY都不应以另一个channel先握手为前提。BVALID只能在本事务AW和W都收到后产生。

  // TODO(AXI-MEM-HANDSHAKE): 将四个SimpleBus握手替换为imem AR/R以及dmem
  // AR/R/AW/W/B共7个握手事件。slave可以等待VALID再拉READY，但为获得单拍接收性能，
  // 空闲且buffer有空间时应提前拉高READY。RVALID/BVALID不得等待RREADY/BREADY才产生。
  //
  // TODO(AXI-MEM-HANDSHAKE-CODE): 删除下面四个旧握手，写成：
  assign ifu_ar_handshake = ifu_axi_arvalid_i && ifu_axi_arready_o;
  assign ifu_r_handshake  = ifu_axi_rvalid_o && ifu_axi_rready_i;
  assign lsu_ar_handshake = lsu_axi_arvalid_i && lsu_axi_arready_o;
  assign lsu_r_handshake  = lsu_axi_rvalid_o && lsu_axi_rready_i;
  assign lsu_aw_handshake = lsu_axi_awvalid_i && lsu_axi_awready_o;
  assign lsu_w_handshake  = lsu_axi_wvalid_i && lsu_axi_wready_o;
  assign lsu_b_handshake  = lsu_axi_bvalid_o && lsu_axi_bready_i;
  //
  always_comb begin
    active_lsu_aw = lsu_aw_handshake ? lsu_axi_aw_i : lsu_aw_q;
    active_lsu_w  = lsu_w_handshake ? lsu_axi_w_i : lsu_w_q;

    lsu_write_request_complete =
        (lsu_write_state_q == WRITE_COLLECT) &&
        (lsu_aw_handshake_occurred_q || lsu_aw_handshake) &&
        (lsu_w_handshake_occurred_q  || lsu_w_handshake);
  end
  //
  // active payload优先选择本拍握手输入，否则选择之前保存的payload，覆盖AW/W任意先后到达。
  // A transfer occurs only when both sides complete the valid/ready handshake.


  initial begin
    // TODO(AXI-MEM-INITIAL-CODE): 参数改名后将检查替换为：
    if (IFU_READ_LATENCY == 0) $fatal(1, "IFU_READ_LATENCY must be >= 1");
    if (LSU_READ_LATENCY == 0) $fatal(1, "LSU_READ_LATENCY must be >= 1");
    if (LSU_WRITE_LATENCY == 0) $fatal(1, "LSU_WRITE_LATENCY must be >= 1");
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
  // TODO(AXI-MEM-IFU-READ-CODE): 删除下面三个旧imem block，替换为完整代码：
  //
  always_comb begin
    ifu_axi_arready_o = 1'b0;
    ifu_axi_r_o       = ifu_r_q;
    ifu_axi_rvalid_o  = 1'b0;

    if (rst_ni) begin
      unique case (ifu_read_state_q)
        READ_IDLE: ifu_axi_arready_o = 1'b1;
        READ_RESP: ifu_axi_rvalid_o = 1'b1;
        default:   ;
      endcase
    end
  end
  //
  always_comb begin
    ifu_read_state_d = ifu_read_state_q;
    ifu_delay_d      = ifu_delay_q;

    unique case (ifu_read_state_q)
      READ_IDLE: begin
        if (ifu_ar_handshake) begin
          if (IFU_READ_LATENCY == 1) begin
            ifu_read_state_d = READ_RESP;
          end else begin
            ifu_delay_d      = IFU_DELAY_W'(IFU_READ_LATENCY - 1);
            ifu_read_state_d = READ_WAIT;
          end
        end
      end

      READ_WAIT: begin
        if (ifu_delay_q == IFU_DELAY_W'(1)) begin
          ifu_delay_d      = '0;
          ifu_read_state_d = READ_RESP;
        end else begin
          ifu_delay_d = ifu_delay_q - IFU_DELAY_W'(1);
        end
      end

      READ_RESP: begin
        if (ifu_r_handshake) begin
          ifu_read_state_d = READ_IDLE;
        end
      end

      default: begin
        ifu_read_state_d = READ_IDLE;
        ifu_delay_d      = '0;
      end
    endcase
  end
  //
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ifu_read_state_q <= READ_IDLE;
      ifu_delay_q      <= '0;
      ifu_r_q          <= '0;
    end else begin
      ifu_read_state_q <= ifu_read_state_d;
      ifu_delay_q      <= ifu_delay_d;

      if (ifu_ar_handshake) begin
        ifu_r_q.data <= pmem_read(int'(ifu_axi_ar_i.addr));
        ifu_r_q.resp <= AXI_RESP_OKAY;
      end
    end
  end




  // TODO(AXI-MEM-DMEM-READ): dmem read使用独立AR/R状态，不再从cmd判断load。
  // 行为与imem read相同，但地址范围错误返回DECERR。对MMIO read要在AR事务被接受后只执行
  // 一次，不能因为RREADY低而重复产生读取副作用。
  //
  // TODO(AXI-MEM-LSU-READ-CODE): 删除下面旧dmem output/next block，替换为：
  //
  always_comb begin
    lsu_axi_arready_o = 1'b0;
    lsu_axi_r_o       = lsu_r_q;
    lsu_axi_rvalid_o  = 1'b0;

    if (rst_ni) begin
      unique case (lsu_read_state_q)
        READ_IDLE: lsu_axi_arready_o = 1'b1;
        READ_RESP: lsu_axi_rvalid_o = 1'b1;
        default:   ;
      endcase
    end
  end
  //
  always_comb begin
    lsu_read_state_d = lsu_read_state_q;
    lsu_read_delay_d = lsu_read_delay_q;

    unique case (lsu_read_state_q)
      READ_IDLE: begin
        if (lsu_ar_handshake) begin
          if (LSU_READ_LATENCY == 1) begin
            lsu_read_state_d = READ_RESP;
          end else begin
            lsu_read_delay_d = LSU_READ_DELAY_W'(LSU_READ_LATENCY - 1);
            lsu_read_state_d = READ_WAIT;
          end
        end
      end

      READ_WAIT: begin
        if (lsu_read_delay_q == LSU_READ_DELAY_W'(1)) begin
          lsu_read_delay_d = '0;
          lsu_read_state_d = READ_RESP;
        end else begin
          lsu_read_delay_d = lsu_read_delay_q - LSU_READ_DELAY_W'(1);
        end
      end

      READ_RESP: begin
        if (lsu_r_handshake) begin
          lsu_read_state_d = READ_IDLE;
        end
      end

      default: begin
        lsu_read_state_d = READ_IDLE;
        lsu_read_delay_d = '0;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_read_state_q <= READ_IDLE;
      lsu_read_delay_q <= '0;
      lsu_r_q          <= '0;
    end else begin
      lsu_read_state_q <= lsu_read_state_d;
      lsu_read_delay_q <= lsu_read_delay_d;

      if (lsu_ar_handshake) begin
        lsu_r_q.data <= pmem_read_data(int'(lsu_axi_ar_i.addr), 4);
        lsu_r_q.resp <= AXI_RESP_OKAY;
      end
    end
  end
  //
  // len固定为4，因为AXI4-Lite接口没有AxSIZE，LSU随后根据原始effective_addr和mem_size
  // 选择byte/halfword。RVALID保持期间不能再次调用pmem_read_data。

  // TODO(AXI-MEM-DMEM-WRITE): 删除下面按dmem_req_handshake执行load/store的块，改为：
  // 1. AW握手时保存AWADDR/AWPROT并置lsu_aw_handshake_occurred_q。
  // 2. W握手时保存WDATA/WSTRB并置lsu_w_handshake_occurred_q。
  // 3. 当历史握手状态或本拍handshake表明两者均已收到时，只执行一次pmem_write。
  // 4. 写延迟到期后产生BRESP和BVALID；BVALID && !BREADY期间保持不变。
  // 5. B握手后允许下一事务。
  //
  // 第3步必须能从寄存器或本拍握手payload中选择正确值，覆盖AW/W同拍到达和任意先后到达。
  // 不要用AWADDR当前输入配对以前保存的W，也不要在只收到一个channel时执行写入。
  // 地址decode失败返回DECERR，写保护/后端错误返回SLVERR；即使错误也必须产生B响应，防止
  // master永久等待。
  //
  // TODO(AXI-MEM-LSU-WRITE-CODE): 删除下面旧dmem寄存器块，替换为以下完整写通道：
  //
  always_comb begin
    lsu_axi_awready_o = 1'b0;
    lsu_axi_wready_o  = 1'b0;
    lsu_axi_b_o       = lsu_b_q;
    lsu_axi_bvalid_o  = 1'b0;

    if (rst_ni) begin
      unique case (lsu_write_state_q)
        WRITE_COLLECT: begin
          lsu_axi_awready_o = !lsu_aw_handshake_occurred_q;
          lsu_axi_wready_o  = !lsu_w_handshake_occurred_q;
        end
        WRITE_RESP: begin
          lsu_axi_bvalid_o = 1'b1;
        end
        default: ;
      endcase
    end
  end
  //
  always_comb begin
    lsu_write_state_d           = lsu_write_state_q;
    lsu_write_delay_d           = lsu_write_delay_q;
    lsu_aw_d                    = lsu_aw_q;
    lsu_w_d                     = lsu_w_q;
    lsu_aw_handshake_occurred_d = lsu_aw_handshake_occurred_q;
    lsu_w_handshake_occurred_d  = lsu_w_handshake_occurred_q;

    unique case (lsu_write_state_q)
      WRITE_COLLECT: begin
        if (lsu_aw_handshake) begin
          lsu_aw_d                    = lsu_axi_aw_i;
          lsu_aw_handshake_occurred_d = 1'b1;
        end
        if (lsu_w_handshake) begin
          lsu_w_d                    = lsu_axi_w_i;
          lsu_w_handshake_occurred_d = 1'b1;
        end

        if (lsu_write_request_complete) begin
          if (LSU_WRITE_LATENCY == 1) begin
            lsu_write_state_d = WRITE_RESP;
          end else begin
            lsu_write_delay_d = LSU_WRITE_DELAY_W'(LSU_WRITE_LATENCY - 1);
            lsu_write_state_d = WRITE_WAIT;
          end
        end
      end

      WRITE_WAIT: begin
        if (lsu_write_delay_q == LSU_WRITE_DELAY_W'(1)) begin
          lsu_write_delay_d = '0;
          lsu_write_state_d = WRITE_RESP;
        end else begin
          lsu_write_delay_d = lsu_write_delay_q - LSU_WRITE_DELAY_W'(1);
        end
      end

      WRITE_RESP: begin
        if (lsu_b_handshake) begin
          lsu_aw_handshake_occurred_d = 1'b0;
          lsu_w_handshake_occurred_d  = 1'b0;
          lsu_write_state_d           = WRITE_COLLECT;
        end
      end

      default: begin
        lsu_write_state_d           = WRITE_COLLECT;
        lsu_write_delay_d           = '0;
        lsu_aw_handshake_occurred_d = 1'b0;
        lsu_w_handshake_occurred_d  = 1'b0;
      end
    endcase
  end
  //
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_write_state_q           <= WRITE_COLLECT;
      lsu_write_delay_q           <= '0;
      lsu_aw_q                    <= '0;
      lsu_w_q                     <= '0;
      lsu_b_q                     <= '0;
      lsu_aw_handshake_occurred_q <= 1'b0;
      lsu_w_handshake_occurred_q  <= 1'b0;
    end else begin
      lsu_write_state_q           <= lsu_write_state_d;
      lsu_write_delay_q           <= lsu_write_delay_d;
      lsu_aw_q                    <= lsu_aw_d;
      lsu_w_q                     <= lsu_w_d;
      lsu_aw_handshake_occurred_q <= lsu_aw_handshake_occurred_d;
      lsu_w_handshake_occurred_q  <= lsu_w_handshake_occurred_d;

      if (lsu_write_request_complete) begin
        pmem_write(int'(active_lsu_aw.addr), int'(active_lsu_w.data), byte'(active_lsu_w.strb));
        lsu_b_q.resp <= AXI_RESP_OKAY;
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

  p_ifu_arprot_known :
  assert property (@(posedge clk_i) ifu_ar_handshake |-> !$isunknown(ifu_axi_ar_i.prot))
  else $error("IFU ARPROT contains X at handshake");

  p_lsu_arprot_known :
  assert property (@(posedge clk_i) lsu_ar_handshake |-> !$isunknown(lsu_axi_ar_i.prot))
  else $error("LSU ARPROT contains X at handshake");

  p_lsu_awprot_known :
  assert property (@(posedge clk_i) lsu_aw_handshake |-> !$isunknown(lsu_axi_aw_i.prot))
  else $error("LSU AWPROT contains X at handshake");

  p_lsu_active_awprot_known :
  assert property (
    @(posedge clk_i) lsu_write_request_complete |-> !$isunknown(active_lsu_aw.prot)
  )
  else $error("Stored LSU AWPROT contains X when write request completes");



endmodule
