#include <am.h>
#include <klib-macros.h>
#include <klib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

uint32_t pc = 0;
uint32_t gpr[32] = {0};
uint8_t memory[0x8000000];
uint8_t vga_fb[0x40000];
void load_image(const char *image_path) {
  // ("rb" = Read Binary)
  FILE *fp = fopen(image_path, "rb");
  if (fp == NULL) {
    printf("Can not open '%s'\n", image_path);
    exit(1); //
  }

  //
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  printf("Image path: %s, size = %ld bytes\n", image_path, size);

  if (size > sizeof(memory)) {
    printf("Error: Image too large for memory!\n");
    fclose(fp);
    exit(1);
  }

  fseek(fp, 0, SEEK_SET);

  int ret = fread(memory, 1, size, fp);
  assert(ret == size);

  fclose(fp);
}

uint32_t fetch_inst(uint32_t addr) {
  return (memory[addr + 3] << 24) | (memory[addr + 2] << 16) |
         (memory[addr + 1] << 8) | memory[addr];
}

int32_t sign_extend(uint32_t imm, int bit_len) {
  int32_t mask = 1 << (bit_len - 1);
  return (imm ^ mask) - mask;
}

void inst_cycle() {
  // Fetch
  uint32_t inst = fetch_inst(pc);

  // x0
  gpr[0] = 0;

  // Decode
  uint32_t opcode = inst & 0x7F;         // [6:0]
  uint32_t rd = (inst >> 7) & 0x1F;      // [11:7]
  uint32_t funct3 = (inst >> 12) & 0x07; // [14:12]
  uint32_t rs1 = (inst >> 15) & 0x1F;    // [19:15]
  uint32_t rs2 = (inst >> 20) & 0x1F;    // [24:20]
  uint32_t funct7 = (inst >> 25) & 0x7F; // [31:25]

  // Immediate
  //  I-Type (ADDI, LW, JALR)
  int32_t imm_i = sign_extend(inst >> 20, 12);
  // S-Type (SW)
  int32_t imm_s = sign_extend(((inst >> 25) << 5) | ((inst >> 7) & 0x1F), 12);
  // U-Type (LUI)
  int32_t imm_u = inst & 0xFFFFF000;

  // LW SW
  uint32_t addr;
  uint32_t val;
  uint32_t offset;
  // printf("PC: %08X | Inst: %08X | Op: %02X | rd: %d\n", pc, inst, opcode,
  // rd);

  uint32_t next_pc = pc + 4; // pc renew

  // Execute
  switch (opcode) {
  // R-Type (ADD)
  case 0x33: {
    if (funct3 == 0x0 && funct7 == 0x00) { // ADD
      gpr[rd] = gpr[rs1] + gpr[rs2];
      printf("EXEC: ADD x%d = x%d(%d) + x%d(%d)\n", rd, rs1, gpr[rs1], rs2,
             gpr[rs2]);
    }
    break;
  }

  // I-Type (ADDI)
  case 0x13: {
    if (funct3 == 0x0) { // ADDI
      gpr[rd] = gpr[rs1] + imm_i;
      printf("EXEC: ADDI x%d = x%d(%d) + %d\n", rd, rs1, gpr[rs1], imm_i);
    }
    break;
  }

  // U-Type (LUI)
  case 0x37: {
    gpr[rd] = imm_u;
    printf("EXEC: LUI x%d = 0x%X\n", rd, imm_u);
    break;
  }

  // I-Type
  case 0x67: {
    if (funct3 == 0x0) {
      // JALR: rd = PC+4; PC = (rs1 + imm) & ~1
      // 注意：必须在跳转前保存 PC+4
      uint32_t link_addr = pc + 4;
      // 计算跳转目标地址，并设置最低位为 0
      next_pc = (gpr[rs1] + imm_i) & ~1;
      gpr[rd] = link_addr;
      printf("EXEC: JALR x%d = PC+4, Jump to %X\n", rd, next_pc);
    }
    break;
  }

  case 0x03: {
    addr = gpr[rs1] + imm_i;

    switch (funct3) {
    case 0x4:                 // LBU (Load Byte Unsigned)
      gpr[rd] = memory[addr]; // uint8 -> uint32 自动零扩展
      printf("EXEC: LBU x%d = Mem[%X](ZeroExt %02X)\n", rd, addr, memory[addr]);
      break;

    case 0x2: // LW (Load Word)
      gpr[rd] = fetch_inst(addr);
      printf("EXEC: LW  x%d = Mem[%X](%08X)\n", rd, addr, gpr[rd]);
      break;

    default:
      printf("Unknown Load Funct3: %d\n", funct3);
      break;
    }
    break;
  }

  // S-Type
  case 0x23: {
    addr = gpr[rs1] + imm_s;
    val = gpr[rs2];
    offset = addr - 0x20000000;
    switch (funct3) {
    case 0x0:                    // SB (Store Byte)
      if (addr >= 0x20000000 && addr < 0x20040000) {
        vga_fb[offset] = val & 0xFF;
        printf("EXEC: SW  vga[%X] = %08X\n", offset, val);
      }
      else{
        memory[addr] = val & 0xFF; //
        printf("EXEC: SB  Mem[%X] = %02X\n", addr, memory[addr]);
      }
      break;

    case 0x2: // SW (Store Word)
      if (addr >= 0x20000000 && addr < 0x20040000) {
        vga_fb[offset] = val & 0xFF;
        vga_fb[offset + 1] = (val >> 8) & 0xFF;
        vga_fb[offset + 2] = (val >> 16) & 0xFF;
        vga_fb[offset + 3] = (val >> 24) & 0xFF;
        printf("EXEC: SW  vga[%X] = %08X\n", offset, val);
      } else {
        memory[addr] = val & 0xFF;
        memory[addr + 1] = (val >> 8) & 0xFF;
        memory[addr + 2] = (val >> 16) & 0xFF;
        memory[addr + 3] = (val >> 24) & 0xFF;
        printf("EXEC: SW  Mem[%X] = %08X\n", addr, val);
      }
      break;
    }
    break;
  }

  case 0x00: 
  {
    io_write(AM_GPU_FBDRAW, 0, 0, (uint32_t *)vga_fb, 256, 256, true);
    while (1);
    break;
  }


  default:
    printf("Unknown Instruction: %08X\n", inst);
    break;
  }

  //
  pc = next_pc;
}

int main(int argc, char *argv[]) {

  load_image("./build/vga.bin");
  uint32_t target_addr = 0xdb0;
  uint32_t ebreak_inst = 0x00000000;
  memory[target_addr + 0] = ebreak_inst & 0xFF;
  memory[target_addr + 1] = (ebreak_inst >> 8) & 0xFF;
  memory[target_addr + 2] = (ebreak_inst >> 16) & 0xFF;
  memory[target_addr + 3] = (ebreak_inst >> 24) & 0xFF;

  printf("--- sCPU Simulation Start ---\n");
  while (1) {
    inst_cycle();
  }
    ;
  return 0;
}
