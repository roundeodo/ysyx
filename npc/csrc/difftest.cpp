#include "cpu.h"
#include "difftest.h"
#include "mem.h"

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { DIFFTEST_TO_DUT, DIFFTEST_TO_REF };

// 这个结构体必须和 NEMU REF 侧 difftest_regcpy() 看到的 CPU_state 布局一致。
// 当前 NPC 只支持 RV32I，因此固定比较 x0-x31 和 pc；NEMU 必须关闭 CONFIG_RVE。
struct DiffTestRegs {
  uint32_t gpr[32];
  uint32_t pc;
};

static bool difftest_enabled = false;
static void *ref_so_handle = nullptr;

// 下面这些函数指针不是普通函数定义，而是“动态链接库里的函数入口地址”。
// dlopen() 打开 NEMU 生成的 .so 后，dlsym() 会按名字查找这些符号，
// 然后把地址保存到函数指针里。之后 NPC 调用 ref_difftest_exec(1)，
// 实际执行的是 NEMU 动态库里的 difftest_exec(1)。
static void (*ref_difftest_memcpy)(uint32_t addr, void *buf, size_t n,
                                   bool direction) = nullptr;
static void (*ref_difftest_regcpy)(void *dut, bool direction) = nullptr;
static void (*ref_difftest_exec)(uint64_t n) = nullptr;
static void (*ref_difftest_raise_intr)(uint64_t NO) = nullptr;

static void fill_dut_regs(DiffTestRegs *r, uint32_t architectural_pc) {
  // 从 Verilator 模型中读取 NPC 当前 architectural state。
  // DiffTest 比较的是体系结构状态，不比较 EXU/LSU 内部临时信号。
  for (int i = 0; i < 32; i++) {
    r->gpr[i] = npc_get_gpr(i);
  }
  r->pc = architectural_pc;
}

static bool checkregs(const DiffTestRegs *ref, const DiffTestRegs *dut,
                      uint32_t pc) {
  // ref 是 NEMU 执行同一条指令后的状态。
  // dut 是 NPC 执行同一条指令后的状态。
  for (int i = 0; i < 32; i++) {
    if (ref->gpr[i] != dut->gpr[i]) {
      printf("DiffTest mismatch after pc=0x%08x\n", pc);
      printf(" x%d: DUT=0x%08x REF=0x%08x\n", i, dut->gpr[i], ref->gpr[i]);
      return false;
    }
  }

  if (ref->pc != dut->pc) {
    printf("DiffTest pc mismatch after pc=0x%08x\n", pc);
    printf(" pc: DUT=0x%08x REF=0x%08x\n", dut->pc, ref->pc);
    return false;
  }
  return true;
}

void difftest_init(bool enable, const char *ref_so_file, long img_size) {
  difftest_enabled = enable;
  if (!enable)
    return;

  // standalone NPC 从传统 pmem 入口启动；ysyxSoC 则从 MROM 启动。
  // 镜像地址、复位 PC 和容量必须来自同一个平台选择，不能混用。
#if defined(NPC_STANDALONE_SIM)
  constexpr uint32_t image_base = LEGACY_PMEM_BASE;
  constexpr uint32_t reset_pc = LEGACY_PMEM_BASE;
  constexpr size_t image_capacity = MEM_SIZE;
  constexpr const char *image_region_name = "pmem";
#elif defined(NPC_YSYXSOC_SIM)
  constexpr uint32_t image_base = MROM_BASE;
  constexpr uint32_t reset_pc = YSYXSOC_RESET_VECTOR;
  constexpr size_t image_capacity = MROM_SIZE;
  constexpr const char *image_region_name = "MROM";
#else
#error "DiffTest simulation platform is not selected"
#endif

  if (img_size <= 0) {
    printf("DiffTest requires a loaded program image\n");
    exit(1);
  }

  if (static_cast<size_t>(img_size) > image_capacity) {
    printf("DiffTest %s image is too large: %ld bytes, capacity=%zu bytes\n",
           image_region_name, img_size, image_capacity);
    exit(1);
  }

  if (ref_so_file == nullptr) {
    printf("DiffTest requires --diff <ref-so>\n");
    exit(1);
  }

  // dlopen() 在运行时打开 NEMU 编译出的动态链接库。
  // RTLD_LAZY 表示符号可以等到第一次使用时再解析，当前 DiffTest 场景够用。
  void *handle = dlopen(ref_so_file, RTLD_LAZY);
  if (handle == nullptr) {
    printf("dlopen failed: %s\n", dlerror());
    exit(1);
  }
  ref_so_handle = handle;

  // dlsym() 按函数名从动态库中取函数地址。
  // C/C++ 不允许 void* 自动转成函数指针，所以这里需要显式类型转换。
  ref_difftest_memcpy = (void (*)(uint32_t, void *, size_t, bool))dlsym(
      handle, "difftest_memcpy");
  ref_difftest_regcpy =
      (void (*)(void *, bool))dlsym(handle, "difftest_regcpy");
  ref_difftest_exec = (void (*)(uint64_t))dlsym(handle, "difftest_exec");
  ref_difftest_raise_intr =
      (void (*)(uint64_t))dlsym(handle, "difftest_raise_intr");
  void (*ref_difftest_init)(int) =
      (void (*)(int))dlsym(handle, "difftest_init");

  if (!ref_difftest_memcpy || !ref_difftest_regcpy || !ref_difftest_exec ||
      !ref_difftest_raise_intr || !ref_difftest_init) {
    printf("dlsym failed: %s\n", dlerror());
    exit(1);
  }

  // NEMU初始化后，将DUT使用的程序镜像复制到REF的同一物理地址。
  ref_difftest_init(0);
  const size_t image_size = static_cast<size_t>(img_size);
  ref_difftest_memcpy(image_base, pmem, image_size, DIFFTEST_TO_REF);

  // 在第一条指令执行前同步全部体系结构状态，避免REF自身的构建默认复位地址
  // 泄漏到比较过程。
  DiffTestRegs dut = {};
  fill_dut_regs(&dut, reset_pc);
  ref_difftest_regcpy(&dut, DIFFTEST_TO_REF);

  printf("DiffTest: ON, REF=%s, image=[0x%08x, +%zu bytes], reset_pc=0x%08x\n",
         ref_so_file, image_base, image_size, reset_pc);
}

void difftest_step(uint32_t pc, uint32_t next_pc) {
  if (!difftest_enabled)
    return;

  ref_difftest_exec(1);

  DiffTestRegs ref;
  DiffTestRegs dut;
  ref_difftest_regcpy(&ref, DIFFTEST_TO_DUT);
  fill_dut_regs(&dut, next_pc);

  if (!checkregs(&ref, &dut, pc)) {
    exit(1);
  }
}

void difftest_cleanup() {
  difftest_enabled = false;

  // 关闭通过 dlopen() 打开的动态库句柄。
  // 当前仿真进程马上退出时不关也通常没事，但显式释放更清楚。
  if (ref_so_handle != nullptr) {
    dlclose(ref_so_handle);
    ref_so_handle = nullptr;
  }
}
