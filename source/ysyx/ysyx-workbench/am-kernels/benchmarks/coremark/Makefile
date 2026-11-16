NAME = coremark
SRCS = $(shell find src/ -name "*.c")
COREMARK_ITERATIONS ?= 1000
CFLAGS += -DITERATIONS=$(COREMARK_ITERATIONS)
include $(AM_HOME)/Makefile
