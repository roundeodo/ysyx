NAME = microbench
SRCS = $(shell find src/ -name "*.c" -o -name "*.cc")
# Historical guest-side PMU diagnostics are opt-in. The default image keeps
# only the benchmark's original timer reads. Clean before changing this option.
ifeq ($(MICROBENCH_CSR_DIAGNOSTICS),1)
CFLAGS += -DMICROBENCH_CSR_DIAGNOSTICS
endif
include $(AM_HOME)/Makefile
