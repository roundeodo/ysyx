// TODO(HP-CSR-0): 完成 commit-only 改造后，将文件和模块重命名为 riscv32_csr_file。
// 该名称明确本模块只保存并访问 CSR architectural state；CSR 指令运算放在 riscv32_csr_exec，
// trap/interrupt 选择与 redirect request 生成放在 riscv32_trap_ctrl，避免重新形成集中式控制器。
module riscv32_CSR
  import riscv32_pkg::*;
#(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 32
) (
    input logic clk,
    input logic rst,

    // TODO(HP-CSR-1): 把 CSR execute/read 与 architectural commit write 分成两组端口。
    // Execute 端口读取 old value、计算 new value、检查权限并形成 completion；Commit 端口携带
    // csr_commit_valid_i/csr_commit_i，只有 ROB 头部授权才能修改下面的 CSR state。
    // trap/mret 也应来自 riscv32_trap_ctrl 的 commit request，不能直接来自当前 IDU。
    input logic                     i_csr_ren,
    input logic                     i_csr_wren,
    input logic    [ADDR_WIDTH-1:0] i_csr_addr,
    input csr_op_t                  i_csr_op,
    input logic    [DATA_WIDTH-1:0] i_csr_src,

    input logic                  i_trap_valid,
    input logic [DATA_WIDTH-1:0] i_trap_mepc,
    input logic [DATA_WIDTH-1:0] i_trap_mcause,

    output logic [DATA_WIDTH-1:0] o_csr_mtvec,
    output logic [DATA_WIDTH-1:0] o_csr_mepc,

    output logic [DATA_WIDTH-1:0] o_csr_rdata,
    output logic                  o_csr_illegal
);

  localparam logic [ADDR_WIDTH-1:0] CSR_MVENDORID = 12'hF11;
  localparam logic [ADDR_WIDTH-1:0] CSR_MARCHID   = 12'hF12;
  localparam logic [ADDR_WIDTH-1:0] CSR_MSTATUS   = 12'h300;
  localparam logic [ADDR_WIDTH-1:0] CSR_MIE       = 12'h304;
  localparam logic [ADDR_WIDTH-1:0] CSR_MTVEC     = 12'h305;
  localparam logic [ADDR_WIDTH-1:0] CSR_MSCRATCH  = 12'h340;
  localparam logic [ADDR_WIDTH-1:0] CSR_MEPC      = 12'h341;
  localparam logic [ADDR_WIDTH-1:0] CSR_MCAUSE    = 12'h342;
  localparam logic [ADDR_WIDTH-1:0] CSR_MIP       = 12'h344;
  localparam logic [ADDR_WIDTH-1:0] CSR_MCYCLE    = 12'hB00;
  localparam logic [ADDR_WIDTH-1:0] CSR_MCYCLEH   = 12'hB80;

  localparam logic [31:0] MVENDORID_VALUE = 32'h7973_7978;  // "ysyx"
  localparam logic [31:0] MARCHID_VALUE   = 32'h0150_be98;  // 22068888

  logic [63:0] mcycle;
  logic [31:0] mstatus;
  logic [31:0] mie;
  logic [31:0] mtvec;
  logic [31:0] mscratch;
  logic [31:0] mepc;
  logic [31:0] mcause;
  logic [31:0] mip;

  logic [DATA_WIDTH-1:0] csr_wdata;
  // TODO(HP-CSR-2): 将下面 CSR RMW 逻辑定义为“候选新值”计算，不要在 execute 时直接写寄存器。
  // CSR completion 应同时携带 old_value（写回 rd）和 new_value（等待 commit）；对于 CSRRS/
  // CSRRC 的 rs1=x0，必须保持无写副作用。加入 CSR immediate 指令时 source 来自 zimm 而非 RF。
  //operation
  always_comb begin
    case (i_csr_op)
      CSR_OP_RW: csr_wdata = i_csr_src;
      CSR_OP_RS: csr_wdata = o_csr_rdata | i_csr_src;
      CSR_OP_RC: csr_wdata = o_csr_rdata & ~i_csr_src;
      default:   csr_wdata = {DATA_WIDTH{1'b0}};
    endcase
  end


  //read
  always_comb begin
    o_csr_rdata   = 32'b0;
    o_csr_illegal = 1'b0;

    if (i_csr_ren) begin
      case (i_csr_addr)
        CSR_MVENDORID: o_csr_rdata = MVENDORID_VALUE;
        CSR_MARCHID:   o_csr_rdata = MARCHID_VALUE;

        CSR_MSTATUS:  o_csr_rdata = mstatus;
        CSR_MIE:      o_csr_rdata = mie;
        CSR_MTVEC:    o_csr_rdata = mtvec;
        CSR_MSCRATCH: o_csr_rdata = mscratch;
        CSR_MEPC:     o_csr_rdata = mepc;
        CSR_MCAUSE:   o_csr_rdata = mcause;
        CSR_MIP:      o_csr_rdata = mip;

        CSR_MCYCLE:  o_csr_rdata = mcycle[31:0];
        CSR_MCYCLEH: o_csr_rdata = mcycle[63:32];

        // TODO(HP-CSR-3): 将非法 CSR 地址/权限错误并入当前 uop 的 exception metadata。
        // 不要在 top 中用 unused_csr_status 吞掉它；completion 应携带 illegal-instruction cause，
        // ROB 提交时由 riscv32_trap_ctrl 写 mepc/mcause 并 redirect 到 mtvec。
        default: begin
          o_csr_rdata   = 32'b0;
          o_csr_illegal = 1'b1;
        end
      endcase
    end
  end

  // TODO(HP-CSR-4): 将下面状态更新改成 commit-only。
  // 优先级建议明确为 reset > committed trap > committed mret > committed CSR write > counters。
  // 被 flush、尚未到 ROB 头部或发生更早异常的 CSR uop 绝不能修改 architectural CSR。
  //write
  always_ff @(posedge clk) begin
    if (rst) begin
      mcycle   <= 64'b0;
      mstatus  <= 32'b0;
      mie      <= 32'b0;
      mtvec    <= 32'b0;
      mscratch <= 32'b0;
      mepc     <= 32'b0;
      mcause   <= 32'b0;
      mip      <= 32'b0;
    end else begin
      mcycle <= mcycle + 1;
      // TODO(HP-CSR-5): 补齐 trap/mret 对 mstatus 的体系结构更新，并为中断留下统一入口。
      // trap 至少保存 mepc/mcause，并更新 MIE/MPIE/MPP；mret 执行相反恢复。
      // timer interrupt 的 pending/enable 判断属于 riscv32_trap_ctrl，CSRFile 只保存 mstatus/mie/mip。
      if (i_trap_valid) begin
        mepc   <= i_trap_mepc;
        mcause <= i_trap_mcause;
      end else if (i_csr_wren) begin
        case (i_csr_addr)
          CSR_MSTATUS:  mstatus <= csr_wdata;
          CSR_MIE:      mie <= csr_wdata;
          CSR_MTVEC:    mtvec <= csr_wdata;
          CSR_MSCRATCH: mscratch <= csr_wdata;
          CSR_MEPC:     mepc <= csr_wdata;
          CSR_MCAUSE:   mcause <= csr_wdata;
          CSR_MIP:      mip <= csr_wdata;
          CSR_MCYCLE:   mcycle[31:0] <= csr_wdata;
          CSR_MCYCLEH:  mcycle[63:32] <= csr_wdata;
          default:      ;
        endcase
      end
    end
  end

  assign o_csr_mtvec = mtvec;
  assign o_csr_mepc  = mepc;

endmodule
