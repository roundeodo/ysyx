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

#include "local-include/reg.h"
#include <cpu/cpu.h>
#include <cpu/ifetch.h>
#include <cpu/decode.h>

#define R(i) gpr(i)
#define Mr vaddr_read
#define Mw vaddr_write

#ifdef CONFIG_FTRACE
void ftrace_call(vaddr_t pc, vaddr_t target);
void ftrace_ret(vaddr_t pc);
#define FTRACE_CALL(pc, target) ftrace_call((pc), (target))
#define FTRACE_RET(pc) ftrace_ret((pc))
#else
#define FTRACE_CALL(pc, target) do {} while (0)
#define FTRACE_RET(pc)         do {} while (0)
#endif



enum {
  TYPE_I, TYPE_U, TYPE_S,
  TYPE_J, TYPE_N, TYPE_B, TYPE_R// none
};

#define src1R() do { *src1 = R(rs1); } while (0)
#define src2R() do { *src2 = R(rs2); } while (0)
#define immI() do { *imm = SEXT(BITS(i, 31, 20), 12); } while(0)
#define immU() do { *imm = SEXT(BITS(i, 31, 12), 20) << 12; } while(0)
#define immS() do { *imm = (SEXT(BITS(i, 31, 25), 7) << 5) | BITS(i, 11, 7); } while(0)
#define immJ()                                                                                                            \
  do                                                                                                                      \
  {                                                                                                                       \
    *imm = (SEXT(BITS(i, 31, 31), 1) << 20) | (BITS(i, 19, 12) << 12) | (BITS(i, 20, 20) << 11) | (BITS(i, 30, 21) << 1); \
  }while(0)
#define immB()                                                                                                        \
  do                                                                                                                  \
  {                                                                                                                   \
    *imm = (SEXT(BITS(i, 31, 31), 1) << 12) | (BITS(i, 7, 7) << 11) | (BITS(i, 30, 25) << 5) | (BITS(i, 11, 8) << 1); \
  }while(0)

static void decode_operand(Decode *s, int *rd, word_t *src1, word_t *src2, word_t *imm, int type) {
  uint32_t i = s->isa.inst;
  int rs1 = BITS(i, 19, 15);
  int rs2 = BITS(i, 24, 20);
  *rd     = BITS(i, 11, 7);
  switch (type) {
    case TYPE_I: src1R();          immI(); break;
    case TYPE_U:                   immU(); break;
    case TYPE_S: src1R(); src2R(); immS(); break;
    case TYPE_J:                   immJ(); break;
    case TYPE_N:
      break;
    case TYPE_B: 
      src1R();
      src2R();
      immB();
      break;
    case TYPE_R:
      src1R();
      src2R();
      break;
    default:
      panic("unsupported type = %d", type);
    }
}

static word_t *csr_decode(word_t csr){
  switch (csr)
  {
  case 0x300: 
    return &cpu.mstatus;
  case 0x305:
    return &cpu.mtvec;
  case 0x341:
    return &cpu.mepc;
  case 0x342:
    return &cpu.mcause;
  default:
    panic("unsupported csr = 0x%llx", (unsigned long long)csr);
  }
}

static word_t csr_read(word_t csr_addr) {
  return *csr_decode(csr_addr);
}

static void csr_write(word_t csr_addr, word_t value) {
  switch (csr_addr) {
  case 0x300:
    cpu.mstatus = 0x1800 | (value & (((word_t)1 << 3) | ((word_t)1 << 7)));
    break;
  case 0x305:
    cpu.mtvec = value & ~(word_t)0x3;
    break;
  case 0x341:
    cpu.mepc = value & ~(word_t)0x3;
    break;
  case 0x342:
    cpu.mcause = value;
    break;
  default:
    panic("unsupported csr = 0x%llx", (unsigned long long)csr_addr);
  }
}

static word_t mret_target(void) {
  const word_t previous_mpie = BITS(cpu.mstatus, 7, 7);
  cpu.mstatus &= ~(((word_t)1 << 3) | ((word_t)1 << 7) |
                   ((word_t)3 << 11));
  cpu.mstatus |= (previous_mpie << 3) | ((word_t)1 << 7) |
                 ((word_t)3 << 11);
  return cpu.mepc;
}

static inline word_t sign_extend_word(uint32_t value) {
  return (word_t)(int64_t)(int32_t)value;
}

static void etrace_mret(vaddr_t pc) {
#ifdef CONFIG_ETRACE
  if (ETRACE_COND) {
    printf("etrace: mret pc=" FMT_WORD
           ", mepc=" FMT_WORD
           ", mstatus=" FMT_WORD
           ", mcause=" FMT_WORD "\n",
           pc, cpu.mepc, cpu.mstatus, cpu.mcause);
  }
#endif
}

static int decode_exec(Decode *s) {
  s->dnpc = s->snpc;

  #define INSTPAT_INST(s) ((s)->isa.inst)  //decode first and extract useful information     and try to match later
  #define INSTPAT_MATCH(s, name, type, ... /* execute body */ ) { \
    int rd = 0; \
    word_t src1 = 0, src2 = 0, imm = 0; \
    decode_operand(s, &rd, &src1, &src2, &imm, concat(TYPE_, type)); \
    __VA_ARGS__ ; \
  }

  INSTPAT_START();

  INSTPAT("??????? ????? ????? ??? ????? 00101 11", auipc, U, R(rd) = s->pc + imm);
  INSTPAT("??????? ????? ????? ??? ????? 01101 11", lui,   U, R(rd) = imm);

  INSTPAT("??????? ????? ????? 000 ????? 00100 11", addi,  I, R(rd) = src1 + imm);
  INSTPAT("??????? ????? ????? 010 ????? 00100 11", slti,  I, R(rd) = (sword_t)src1 < (sword_t)imm);
  INSTPAT("??????? ????? ????? 011 ????? 00100 11", sltiu, I, R(rd) = src1 < imm);
  INSTPAT("??????? ????? ????? 100 ????? 00100 11", xori,  I, R(rd) = src1 ^ imm);
  INSTPAT("??????? ????? ????? 110 ????? 00100 11", ori,   I, R(rd) = src1 | imm);
  INSTPAT("??????? ????? ????? 111 ????? 00100 11", andi,  I, R(rd) = src1 & imm);
  INSTPAT("000000? ????? ????? 001 ????? 00100 11", slli,  I, R(rd) = src1 << BITS(s->isa.inst, 25, 20));
  INSTPAT("000000? ????? ????? 101 ????? 00100 11", srli,  I, R(rd) = src1 >> BITS(s->isa.inst, 25, 20));
  INSTPAT("010000? ????? ????? 101 ????? 00100 11", srai,  I, R(rd) = (word_t)((sword_t)src1 >> BITS(s->isa.inst, 25, 20)));

  INSTPAT("??????? ????? ????? 000 ????? 00110 11", addiw, I, R(rd) = sign_extend_word((uint32_t)(src1 + imm)));
  INSTPAT("0000000 ????? ????? 001 ????? 00110 11", slliw, I, R(rd) = sign_extend_word((uint32_t)src1 << BITS(s->isa.inst, 24, 20)));
  INSTPAT("0000000 ????? ????? 101 ????? 00110 11", srliw, I, R(rd) = sign_extend_word((uint32_t)src1 >> BITS(s->isa.inst, 24, 20)));
  INSTPAT("0100000 ????? ????? 101 ????? 00110 11", sraiw, I, R(rd) = sign_extend_word((uint32_t)((int32_t)src1 >> BITS(s->isa.inst, 24, 20))));

  INSTPAT("??????? ????? ????? 000 ????? 00000 11", lb,  I, R(rd) = SEXT(Mr(src1 + imm, 1), 8));
  INSTPAT("??????? ????? ????? 001 ????? 00000 11", lh,  I, R(rd) = SEXT(Mr(src1 + imm, 2), 16));
  INSTPAT("??????? ????? ????? 010 ????? 00000 11", lw,  I, R(rd) = SEXT(Mr(src1 + imm, 4), 32));
  INSTPAT("??????? ????? ????? 011 ????? 00000 11", ld,  I, R(rd) = Mr(src1 + imm, 8));
  INSTPAT("??????? ????? ????? 100 ????? 00000 11", lbu, I, R(rd) = Mr(src1 + imm, 1));
  INSTPAT("??????? ????? ????? 101 ????? 00000 11", lhu, I, R(rd) = Mr(src1 + imm, 2));
  INSTPAT("??????? ????? ????? 110 ????? 00000 11", lwu, I, R(rd) = Mr(src1 + imm, 4));

  INSTPAT("??????? ????? ????? 000 ????? 11001 11", jalr, I,
          word_t target = (src1 + imm) & ~(word_t)1;
          int rs1_idx = BITS(s->isa.inst, 19, 15);
          R(rd) = s->pc + 4;
          s->dnpc = target;
          if (rd == 1 || rd == 5) FTRACE_CALL(s->pc, target);
          else if (rd == 0 && (rs1_idx == 1 || rs1_idx == 5) && imm == 0) FTRACE_RET(s->pc);
        );

  INSTPAT("0000000 ????? ????? 000 ????? 01100 11", add,  R, R(rd) = src1 + src2);
  INSTPAT("0100000 ????? ????? 000 ????? 01100 11", sub,  R, R(rd) = src1 - src2);
  INSTPAT("0000000 ????? ????? 001 ????? 01100 11", sll,  R, R(rd) = src1 << (src2 & 0x3f));
  INSTPAT("0000000 ????? ????? 010 ????? 01100 11", slt,  R, R(rd) = (sword_t)src1 < (sword_t)src2);
  INSTPAT("0000000 ????? ????? 011 ????? 01100 11", sltu, R, R(rd) = src1 < src2);
  INSTPAT("0000000 ????? ????? 100 ????? 01100 11", xor,  R, R(rd) = src1 ^ src2);
  INSTPAT("0000000 ????? ????? 101 ????? 01100 11", srl,  R, R(rd) = src1 >> (src2 & 0x3f));
  INSTPAT("0100000 ????? ????? 101 ????? 01100 11", sra,  R, R(rd) = (word_t)((sword_t)src1 >> (src2 & 0x3f)));
  INSTPAT("0000000 ????? ????? 110 ????? 01100 11", or,   R, R(rd) = src1 | src2);
  INSTPAT("0000000 ????? ????? 111 ????? 01100 11", and,  R, R(rd) = src1 & src2);

  INSTPAT("0000000 ????? ????? 000 ????? 01110 11", addw, R, R(rd) = sign_extend_word((uint32_t)(src1 + src2)));
  INSTPAT("0100000 ????? ????? 000 ????? 01110 11", subw, R, R(rd) = sign_extend_word((uint32_t)(src1 - src2)));
  INSTPAT("0000000 ????? ????? 001 ????? 01110 11", sllw, R, R(rd) = sign_extend_word((uint32_t)src1 << (src2 & 0x1f)));
  INSTPAT("0000000 ????? ????? 101 ????? 01110 11", srlw, R, R(rd) = sign_extend_word((uint32_t)src1 >> (src2 & 0x1f)));
  INSTPAT("0100000 ????? ????? 101 ????? 01110 11", sraw, R, R(rd) = sign_extend_word((uint32_t)((int32_t)src1 >> (src2 & 0x1f))));

  INSTPAT("??????? ????? ????? ??? ????? 11011 11", jal, J,
          R(rd) = s->pc + 4;
          s->dnpc = s->pc + imm;
          if (rd == 1 || rd == 5) FTRACE_CALL(s->pc, s->dnpc);
        );

  INSTPAT("??????? ????? ????? 000 ????? 01000 11", sb, S, Mw(src1 + imm, 1, src2));
  INSTPAT("??????? ????? ????? 001 ????? 01000 11", sh, S, Mw(src1 + imm, 2, src2));
  INSTPAT("??????? ????? ????? 010 ????? 01000 11", sw, S, Mw(src1 + imm, 4, src2));
  INSTPAT("??????? ????? ????? 011 ????? 01000 11", sd, S, Mw(src1 + imm, 8, src2));

  INSTPAT("??????? ????? ????? 000 ????? 11000 11", beq,  B, if (src1 == src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 001 ????? 11000 11", bne,  B, if (src1 != src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 100 ????? 11000 11", blt,  B, if ((sword_t)src1 < (sword_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 101 ????? 11000 11", bge,  B, if ((sword_t)src1 >= (sword_t)src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 110 ????? 11000 11", bltu, B, if (src1 < src2) s->dnpc = s->pc + imm);
  INSTPAT("??????? ????? ????? 111 ????? 11000 11", bgeu, B, if (src1 >= src2) s->dnpc = s->pc + imm);

  INSTPAT("??????? ????? ????? 000 ????? 00011 11", fence,   N, (void)0);
  INSTPAT("??????? ????? ????? 001 ????? 00011 11", fence_i, N, (void)0);


  INSTPAT("??????? ????? ????? 001 ????? 11100 11", csrrw, I, word_t csr_addr = BITS(s->isa.inst, 31, 20); word_t old = csr_read(csr_addr); csr_write(csr_addr, src1); if (rd != 0) { R(rd) = old; });
  INSTPAT("??????? ????? ????? 010 ????? 11100 11", csrrs, I, word_t csr_addr = BITS(s->isa.inst, 31, 20); word_t old = csr_read(csr_addr); if (BITS(s->isa.inst, 19, 15) != 0) { csr_write(csr_addr, old | src1); } if (rd != 0) { R(rd) = old; });
  INSTPAT("??????? ????? ????? 011 ????? 11100 11", csrrc, I, word_t csr_addr = BITS(s->isa.inst, 31, 20); word_t old = csr_read(csr_addr); if (BITS(s->isa.inst, 19, 15) != 0) { csr_write(csr_addr, old & ~src1); } if (rd != 0) { R(rd) = old; });
  INSTPAT("??????? ????? ????? 101 ????? 11100 11", csrrwi, I, word_t csr_addr = BITS(s->isa.inst, 31, 20); word_t old = csr_read(csr_addr); csr_write(csr_addr, BITS(s->isa.inst, 19, 15)); if (rd != 0) { R(rd) = old; });
  INSTPAT("??????? ????? ????? 110 ????? 11100 11", csrrsi, I, word_t csr_addr = BITS(s->isa.inst, 31, 20); word_t old = csr_read(csr_addr); word_t zimm = BITS(s->isa.inst, 19, 15); if (zimm != 0) { csr_write(csr_addr, old | zimm); } if (rd != 0) { R(rd) = old; });
  INSTPAT("??????? ????? ????? 111 ????? 11100 11", csrrci, I, word_t csr_addr = BITS(s->isa.inst, 31, 20); word_t old = csr_read(csr_addr); word_t zimm = BITS(s->isa.inst, 19, 15); if (zimm != 0) { csr_write(csr_addr, old & ~zimm); } if (rd != 0) { R(rd) = old; });
  INSTPAT("0000000 00000 00000 000 00000 11100 11", ecall, N, s->dnpc = isa_raise_intr(11, s->pc));
  INSTPAT("0011000 00010 00000 000 00000 11100 11", mret,  N, etrace_mret(s->pc); s->dnpc = mret_target());
  INSTPAT("0000000 00001 00000 000 00000 11100 11", ebreak, N, NEMUTRAP(s->pc, R(10))); // R(10) is $a0

  INSTPAT("??????? ????? ????? ??? ????? ????? ??", inv    , N, INV(s->pc));
  INSTPAT_END();

  R(0) = 0; // reset $zero to 0

  return 0;
}

int isa_exec_once(Decode *s) {
  s->isa.inst = inst_fetch(&s->snpc, 4);
  return decode_exec(s);
}
