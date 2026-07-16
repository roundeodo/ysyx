${NPC_HOME}/vsrc/riscv32/riscv32_pkg.sv
// TODO(HP-NAME-1): 新增或重构模块时统一采用以下 SystemVerilog 命名规范：
// RTL 语法风格以 lowRISC/Ibex 的 SystemVerilog 约定为主；uop/rename/issue/ROB/commit
// 等微架构术语参考 BOOM、XiangShan 和 CVA6。不要照搬 Chisel 的 UpperCamelCase 类名。
//   file/module : lower_snake_case，且一文件一模块，例如 riscv32_branch_unit.sv
//   instance    : u_<module_role>，例如 u_branch_unit
//   input/output: 语义名 + _i/_o，例如 execute_req_i、execute_req_valid_i
//   register    : 当前值 _q、下一值 _d；active-low reset 使用 rst_ni
//   typedef     : struct/type 用 _t，enum type 用 _e；常量使用 UPPER_SNAKE_CASE
// 只保留 ALU、CSR、LSU、ROB、PRF 等行业通用缩写；禁止新增 RDU/WBU 这类职责不明确缩写。
//
// TODO(HP-FILELIST-1A): 完成 IDU bundle 后，先建立可验证的顺序提交基础，并在本行下方加入：
//   riscv32_core.sv             - 纯 CPU 边界，不包含 DPI/仿真内存
//   riscv32_commit.sv           - 当前可先实现单入口顺序提交，统一授权 GPR/CSR/store/trap
//   riscv32_trap_ctrl.sv        - 在 commit 点选择 exception/interrupt/mret 并产生 redirect_req_t
//   riscv32_sim_mem.sv          - 只负责仿真 memory request/response 与 DPI 适配
//   riscv32_sim_debug.sv        - 只消费 commit packet，服务 trace/DiffTest/ebreak
// 每创建一个模块就立即接线和 lint；不要一次创建没有行为的空壳。

// TODO(HP-FILELIST-1A-IDU): 只有准备把 decode width 扩展到 2 条或更多时，才在本行下方加入：
//   riscv32_decode_lane.sv。
// lane 只做单条指令的纯组合 decode；riscv32_idu 继续负责 fetch/decode 握手、lane 顺序、
// 输出压缩和 backpressure。单发射阶段不要为了名称完整而额外创建一层空 wrapper。

// TODO(HP-FILELIST-1B): 拆分现有 EXU 时，在本行下方加入独立执行单元：
//   riscv32_int_alu.sv, riscv32_branch_unit.sv, riscv32_agu.sv,
//   riscv32_csr_exec.sv, riscv32_completion_arbiter.sv。
// 每个执行单元只接收匹配 fu_type 的 execute_req_t，并输出统一 completion_t；不要保留
// “所有指令 EXU -> LSU -> WBU”的固定串行路径。

// TODO(HP-FILELIST-1C): 开始乱序执行时，按数据依赖顺序在本行下方加入：
//   riscv32_rename.sv, riscv32_free_list.sv, riscv32_phys_regfile.sv,
//   riscv32_dispatch.sv, riscv32_int_issue_queue.sv, riscv32_mem_issue_queue.sv,
//   riscv32_rob.sv, riscv32_lsq.sv, riscv32_store_buffer.sv。
// rename 同周期完成 RAT 查询/新 pdst 分配/旧 pdst 保存；ROB 保证精确异常和顺序提交；
// issue queue 负责 wakeup/select；LSQ 负责 load/store 顺序、转发和 violation recovery。

// TODO(HP-FILELIST-1D): 后端协议稳定后再扩展前端和存储层次，在本行下方加入：
//   riscv32_fetch_queue.sv, riscv32_branch_predictor.sv,
//   riscv32_icache.sv, riscv32_dcache.sv。
// predictor 只产生预测 metadata；最终 redirect/flush 仍经过 riscv32_redirect_arbiter。
// 不要在 IFU 内直接耦合 ROB、LSQ 或 commit 的内部实现。

// TODO(HP-FILELIST-2): 完成各自接口 TODO 后，重命名现有文件/模块并同步这里的条目：
//   riscv32_RDU.sv  -> riscv32_redirect_arbiter.sv
//   riscv32_CSR.sv  -> riscv32_csr_file.sv
//   RegisterFile.sv -> riscv32_arch_regfile.sv
// 重命名必须一次完成 file/module/instance/filelist，不保留重复 wrapper。
${NPC_HOME}/vsrc/riscv32/RegisterFile.sv
${NPC_HOME}/vsrc/riscv32/riscv32_CSR.sv
${NPC_HOME}/vsrc/riscv32/riscv32_idu.sv
${NPC_HOME}/vsrc/riscv32/riscv32_EXU.sv
${NPC_HOME}/vsrc/riscv32/riscv32_RDU.sv
${NPC_HOME}/vsrc/riscv32/riscv32_IFU.sv
${NPC_HOME}/vsrc/riscv32/riscv32_LSU.sv
${NPC_HOME}/vsrc/riscv32/riscv32_WBU.sv
${NPC_HOME}/vsrc/riscv32/top.sv
