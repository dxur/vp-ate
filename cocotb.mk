SIM := verilator
SIM_BUILD = build/$(TOPLEVEL)
TOPLEVEL_LANG := verilog

RTL_DIR := rtl
BASE_RTL := $(shell find $(RTL_DIR) -name "*.sv")

ifneq ($(EXTRA_RTL),)
VERILOG_SOURCES := $(EXTRA_RTL)
else
VERILOG_SOURCES := $(BASE_RTL)
endif

VERILATOR_ARGS += --sv -O3 --x-assign fast --x-initial fast --trace --trace-structs

include $(shell cocotb-config --makefiles)/Makefile.sim
