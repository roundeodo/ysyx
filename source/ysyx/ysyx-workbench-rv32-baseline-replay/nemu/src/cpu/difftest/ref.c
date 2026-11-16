/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <isa.h>
#include <cpu/cpu.h>
#include <difftest-def.h>
#include <memory/paddr.h>
#include <string.h>

__EXPORT void difftest_memcpy(paddr_t addr, void *buf, size_t n, bool direction) {
  // REF 是 NEMU，DUT 是 NPC。
  // DIFFTEST_TO_REF: 把 NPC 里的内存镜像复制到 NEMU 内存。
  // DIFFTEST_TO_DUT: 把 NEMU 内存复制回调用者，当前 NPC 最小实现一般用不到。
  if(direction == DIFFTEST_TO_REF){
    memcpy(guest_to_host(addr), buf, n);
  }
  else{
    memcpy(buf, guest_to_host(addr), n);
  }
}

__EXPORT void difftest_regcpy(void *dut, bool direction) {
  // 这里直接按 DIFFTEST_REG_SIZE 拷贝 CPU_state。
  // 所以 NPC 侧的 DiffTestRegs 布局必须和 NEMU 的 CPU_state 一致。
  // NPC要求CONFIG_RVE=n；布局为gpr[32]、pc、mstatus、mtvec、mepc、mcause、mtval。
  // 每个字段的宽度由NEMU的CONFIG_RV64和NPC_XLEN共同决定。
  if(direction == DIFFTEST_TO_REF){
    memcpy(&cpu, dut, DIFFTEST_REG_SIZE);
  }
  else{
    memcpy(dut, &cpu, DIFFTEST_REG_SIZE);
  }
}

__EXPORT void difftest_exec(uint64_t n) {
  // 让 REF=NEMU 按自己的解释器执行 n 条指令。
  // NPC 每 commit 一条指令，就让 NEMU exec(1)，然后比较寄存器和 pc。
  cpu_exec(n);
}

__EXPORT void difftest_raise_intr(word_t NO) {
  assert(0);
}

__EXPORT void difftest_init(int port) {
  // 当前 NEMU REF 不使用 port。
  // (void)port 的含义是显式标记“这个参数目前有意不用”，避免编译器报警。
  (void)port;
  void init_mem();
  init_mem();
  /* Perform ISA dependent initialization. */
  init_isa();
}
