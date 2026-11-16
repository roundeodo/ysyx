#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
uint8_t pc = 0;
uint8_t gpr[4] = {0};
uint8_t memory[16] = {0x90, 0xa0, 0xb1, 0x17, 0x26, 0xcd, 0x42, 0x00};

void inst_cycle() {
  while (pc < 16) {
    // --- 1. Fetch ---
    uint8_t inst = memory[pc];
    printf("DEBUG: PC=%X, Inst=%02X, R0=%d, R1=%d\n", pc, inst, gpr[0], gpr[1]);

    if (inst == 0 && pc != 0) {
      printf("Hit HALT (0x00), simulation stop.\n");
      exit(0);
    }

    pc = (pc + 1) & 0x0F; // pc renew

    // --- 2. Decode ---
    uint8_t op = (inst >> 6) & 0x03;  // [7:6]
    uint8_t rd = (inst >> 4) & 0x03;  // [5:4]
    uint8_t rs1 = (inst >> 2) & 0x03; // [3:2]
    uint8_t rs2 = inst & 0x03;        // [1:0]

    //
    uint8_t imm = inst & 0x0F;         // [3:0] for LI
    uint8_t addr = (inst >> 2) & 0x0F; // [5:2] for BNER0

    // --- 3. Execute ---
    switch (op) {
    case 0x00: // ADD: rd = rs1 + rs2
      gpr[rd] = gpr[rs1] + gpr[rs2];
      break;

    case 0x02: // LI: rd = imm
      gpr[rd] = imm;
      break;

    case 0x03: // BNER0: if (r0 != rs2) pc = addr
      if (gpr[0] != gpr[rs2]) {
        pc = addr;
      }
      break;

    case 0x01: // OUTPUT: print rs2
      printf("%d\n", gpr[rs2]);
      break;
    }

    if (inst == 0)
      break;
  }
}

int main(int argc,char *argv[]) {
  if(argc != 2){
    printf("Usage: ./sEMU <n>\n");
    return 1;
  }
  uint8_t input_value = (uint8_t)atoi(argv[1]);
  gpr[0] = input_value;
  while (1)
  {
    inst_cycle();
  }

  return 0;
}
