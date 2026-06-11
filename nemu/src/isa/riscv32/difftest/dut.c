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
#include <cpu/difftest.h>
#include "../local-include/reg.h"

bool isa_difftest_checkregs(CPU_state *ref_r, vaddr_t pc) {
  int nr_gpr = sizeof(cpu.gpr) / sizeof(cpu.gpr[0]);
  for (int i = 0; i < nr_gpr; i++){
    if(cpu.gpr[i] != ref_r->gpr[i]){
      printf("DiffTest register mismatch after executing instruction at pc = " FMT_WORD "\n", pc);
      printf(" reg[%d] mismatch\n", i);
      printf(" DUT = " FMT_WORD "\n", cpu.gpr[i]);
      printf(" REF = " FMT_WORD "\n", ref_r->gpr[i]);

      return false;
    }
  }
  
  // we should compare pc + 4, but the pc here is the address of the instruction that is currently executing
  if(cpu.pc != ref_r->pc){
    printf("DiffTest pc mismatch after executing instruction at pc = " FMT_WORD "\n", pc);
    printf(" DUT pc = " FMT_WORD "\n", cpu.pc);
    printf(" REF pc = " FMT_WORD "\n", ref_r->pc);

    return false;
  }
  return true;
}

void isa_difftest_attach() {
}
