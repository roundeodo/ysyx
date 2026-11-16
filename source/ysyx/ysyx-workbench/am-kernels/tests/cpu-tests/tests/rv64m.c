#include "trap.h"

#if __riscv_xlen == 64

#define DEFINE_RV64M_OPERATION(function_name, instruction_name)                 \
  static inline uint64_t function_name(uint64_t lhs, uint64_t rhs) {            \
    uint64_t result;                                                            \
    asm volatile(instruction_name " %0, %1, %2"                                \
                 : "=r"(result)                                                \
                 : "r"(lhs), "r"(rhs));                                       \
    return result;                                                              \
  }

DEFINE_RV64M_OPERATION(execute_mul, "mul")
DEFINE_RV64M_OPERATION(execute_mulh, "mulh")
DEFINE_RV64M_OPERATION(execute_mulhsu, "mulhsu")
DEFINE_RV64M_OPERATION(execute_mulhu, "mulhu")
DEFINE_RV64M_OPERATION(execute_div, "div")
DEFINE_RV64M_OPERATION(execute_divu, "divu")
DEFINE_RV64M_OPERATION(execute_rem, "rem")
DEFINE_RV64M_OPERATION(execute_remu, "remu")
DEFINE_RV64M_OPERATION(execute_mulw, "mulw")
DEFINE_RV64M_OPERATION(execute_divw, "divw")
DEFINE_RV64M_OPERATION(execute_divuw, "divuw")
DEFINE_RV64M_OPERATION(execute_remw, "remw")
DEFINE_RV64M_OPERATION(execute_remuw, "remuw")

#endif

int main() {
#if __riscv_xlen == 64
  const uint64_t negative_sixteen = UINT64_C(0xfffffffffffffff0);
  const uint64_t minimum_signed   = UINT64_C(0x8000000000000000);

  check(execute_mul(negative_sixteen, 16) == UINT64_C(0xffffffffffffff00));
  check(execute_mulh(negative_sixteen, 16) == UINT64_MAX);
  check(execute_mulhsu(negative_sixteen, 16) == UINT64_MAX);
  check(execute_mulhu(negative_sixteen, 16) == UINT64_C(0xf));

  check(execute_div(minimum_signed, UINT64_MAX) == minimum_signed);
  check(execute_div(123, 0) == UINT64_MAX);
  check(execute_divu(123, 0) == UINT64_MAX);
  check(execute_rem(minimum_signed, UINT64_MAX) == 0);
  check(execute_rem(123, 0) == 123);
  check(execute_remu(123, 0) == 123);

  check(execute_mulw(UINT64_C(0xffffffff), 2) ==
        UINT64_C(0xfffffffffffffffe));
  check(execute_divw(UINT64_C(0x80000000), UINT64_C(0xffffffff)) ==
        UINT64_C(0xffffffff80000000));
  check(execute_divuw(UINT64_C(0x80000000), 1) ==
        UINT64_C(0xffffffff80000000));
  check(execute_remw(UINT64_C(0x80000000), 0) ==
        UINT64_C(0xffffffff80000000));
  check(execute_remuw(UINT64_C(0xffffffff), 2) == 1);
#endif

  return 0;
}
