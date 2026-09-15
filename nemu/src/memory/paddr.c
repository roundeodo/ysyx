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

#include <memory/host.h>
#include <memory/paddr.h>
#include <device/mmio.h>
#include <isa.h>

#if defined(CONFIG_PMEM_MALLOC)
static uint8_t *pmem = NULL;
#else
static uint8_t pmem[CONFIG_MSIZE] PG_ALIGN = {};
#endif

#ifdef CONFIG_YSYXSOC_MEMORY
static uint8_t sram[SRAM_SIZE] PG_ALIGN = {};
#endif

static bool access_inside_region(paddr_t addr, int len,
    paddr_t region_start, paddr_t region_end) {
  return len > 0 && addr >= region_start && addr <= region_end &&
      (paddr_t)(len - 1) <= region_end - addr;
}

static bool access_inside_memory(paddr_t addr, int len) {
  if (access_inside_region(addr, len, PMEM_LEFT, PMEM_RIGHT)) {
    return true;
  }

#ifdef CONFIG_YSYXSOC_MEMORY
  if (access_inside_region(addr, len, SRAM_LEFT, SRAM_RIGHT)) {
    return true;
  }
#endif

  return false;
}

uint8_t *guest_to_host(paddr_t paddr) {
  if (in_pmem(paddr)) {
    return pmem + (paddr - PMEM_LEFT);
  }

#ifdef CONFIG_YSYXSOC_MEMORY
  if (in_sram(paddr)) {
    return sram + (paddr - SRAM_LEFT);
  }
#endif

  panic("address " FMT_PADDR " is not backed by memory", paddr);
}

paddr_t host_to_guest(uint8_t *haddr) {
  uintptr_t host_addr = (uintptr_t)haddr;
  uintptr_t pmem_addr = (uintptr_t)pmem;

  if (host_addr - pmem_addr < CONFIG_MSIZE) {
    return PMEM_LEFT + (host_addr - pmem_addr);
  }

#ifdef CONFIG_YSYXSOC_MEMORY
  uintptr_t sram_addr = (uintptr_t)sram;

  if (host_addr - sram_addr < SRAM_SIZE) {
    return SRAM_LEFT + (host_addr - sram_addr);
  }
#endif

  panic("host address %p is not backed by guest memory", haddr);
}

static word_t memory_read(paddr_t addr, int len) {
  return host_read(guest_to_host(addr), len);
}

static void memory_write(paddr_t addr, int len, word_t data) {
  host_write(guest_to_host(addr), len, data);
}

#ifndef CONFIG_DEVICE
static void out_of_bound(paddr_t addr) {
#ifdef CONFIG_YSYXSOC_MEMORY
  panic("address = " FMT_PADDR " is outside MROM [" FMT_PADDR
      ", " FMT_PADDR "] and SRAM [" FMT_PADDR ", " FMT_PADDR
      "] at pc = " FMT_WORD,
      addr, PMEM_LEFT, PMEM_RIGHT, SRAM_LEFT, SRAM_RIGHT, cpu.pc);
#else
  panic("address = " FMT_PADDR " is outside physical memory ["
      FMT_PADDR ", " FMT_PADDR "] at pc = " FMT_WORD,
      addr, PMEM_LEFT, PMEM_RIGHT, cpu.pc);
#endif
}
#endif

void init_mem(void) {
#if defined(CONFIG_PMEM_MALLOC)
  pmem = malloc(CONFIG_MSIZE);
  assert(pmem);
#endif

#ifdef CONFIG_MEM_RANDOM
  memset(pmem, rand(), CONFIG_MSIZE);
#endif

#ifdef CONFIG_YSYXSOC_MEMORY
#ifdef CONFIG_MEM_RANDOM
  memset(sram, rand(), SRAM_SIZE);
#endif

  Log("MROM area [" FMT_PADDR ", " FMT_PADDR "]",
      PMEM_LEFT, PMEM_RIGHT);
  Log("SRAM area [" FMT_PADDR ", " FMT_PADDR "]",
      SRAM_LEFT, SRAM_RIGHT);
#else
  Log("physical memory area [" FMT_PADDR ", " FMT_PADDR "]",
      PMEM_LEFT, PMEM_RIGHT);
#endif
}

word_t paddr_read(paddr_t addr, int len) {
  if (likely(access_inside_memory(addr, len))) {
    word_t data = memory_read(addr, len);

#ifdef CONFIG_MTRACE
    if (MTRACE_COND) {
      printf("mtrace: read addr = " FMT_PADDR
          ", len = %d, data = " FMT_WORD "\n", addr, len, data);
    }
#endif

    return data;
  }

#ifdef CONFIG_DEVICE
  word_t data = mmio_read(addr, len);

#ifdef CONFIG_MTRACE
  if (MTRACE_COND) {
    printf("mtrace: mmio read addr = " FMT_PADDR
        ", len = %d, data = " FMT_WORD "\n", addr, len, data);
  }
#endif

  return data;
#else
  out_of_bound(addr);
  return 0;
#endif
}

void paddr_write(paddr_t addr, int len, word_t data) {
#ifdef CONFIG_YSYXSOC_MEMORY
  if (in_pmem(addr)) {
    panic("CPU writes read-only MROM at " FMT_PADDR, addr);
  }
#endif

  if (likely(access_inside_memory(addr, len))) {
#ifdef CONFIG_MTRACE
    if (MTRACE_COND) {
      printf("mtrace: write addr = " FMT_PADDR
          ", len = %d, data = " FMT_WORD "\n", addr, len, data);
    }
#endif

    memory_write(addr, len, data);
    return;
  }

#ifdef CONFIG_DEVICE
#ifdef CONFIG_MTRACE
  if (MTRACE_COND) {
    printf("mtrace: mmio write addr = " FMT_PADDR
        ", len = %d, data = " FMT_WORD "\n", addr, len, data);
  }
#endif

  mmio_write(addr, len, data);
  return;
#else
  out_of_bound(addr);
#endif
}
