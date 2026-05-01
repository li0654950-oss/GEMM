# GEMM RTL Simulation Makefile
# Supports: Verilator, Icarus Verilog (iverilog), VCS, Questa (vsim)

RTL_DIR   = ../rtl
TB_DIR    = .
BUILD_DIR = build

# Default simulator (override with SIM=verilator|iverilog|vcs|questa)
SIM ?= iverilog

# Default target (override with TARGET=pe_cell|systolic_core|buffer_bank|a_loader|b_loader|d_storer)
TARGET ?= pe_cell

# Sources per target
ifeq ($(TARGET),pe_cell)
  RTL_SRC  = $(RTL_DIR)/pe_cell.sv
  TB_SRC   = $(TB_DIR)/tb_pe_cell.sv
  TOP      = tb_pe_cell
else ifeq ($(TARGET),systolic_core)
  RTL_SRC  = $(RTL_DIR)/pe_cell.sv $(RTL_DIR)/array_io_adapter.sv $(RTL_DIR)/systolic_core.sv
  TB_SRC   = $(TB_DIR)/tb_systolic_core.sv
  TOP      = tb_systolic_core
else ifeq ($(TARGET),buffer_bank)
  RTL_SRC  = $(RTL_DIR)/buffer_bank.sv
  TB_SRC   = $(TB_DIR)/tb_buffer_bank.sv
  TOP      = tb_buffer_bank
else ifeq ($(TARGET),a_loader)
  RTL_SRC  = $(RTL_DIR)/buffer_bank.sv $(RTL_DIR)/a_loader.sv
  TB_SRC   = $(TB_DIR)/tb_a_loader.sv
  TOP      = tb_a_loader
else ifeq ($(TARGET),b_loader)
  RTL_SRC  = $(RTL_DIR)/buffer_bank.sv $(RTL_DIR)/b_loader.sv
  TB_SRC   = $(TB_DIR)/tb_b_loader.sv
  TOP      = tb_b_loader
else ifeq ($(TARGET),d_storer)
  RTL_SRC  = $(RTL_DIR)/buffer_bank.sv $(RTL_DIR)/d_storer.sv
  TB_SRC   = $(TB_DIR)/tb_d_storer.sv
  TOP      = tb_d_storer
else
  $(error Unknown TARGET=$(TARGET). Supported: pe_cell, systolic_core, buffer_bank, a_loader, b_loader, d_storer)
endif

# Target
.PHONY: all compile run clean

all: run

#---------------------------------------------------------------------
# Icarus Verilog
#---------------------------------------------------------------------
ifeq ($(SIM),iverilog)

compile: $(BUILD_DIR)/$(TOP).out

$(BUILD_DIR)/$(TOP).out: $(RTL_SRC) $(TB_SRC)
	@mkdir -p $(BUILD_DIR)
	iverilog -g2012 -o $@ $(RTL_SRC) $(TB_SRC)

run: compile
	vvp $(BUILD_DIR)/$(TOP).out

#---------------------------------------------------------------------
# Verilator
#---------------------------------------------------------------------
else ifeq ($(SIM),verilator)

# Verilator Makefile adapted for Verilator 5.x
# Verilator 5.x requires --timing for event controls and delay statements
# Uses sim_main.cpp as C++ wrapper

VERILATOR_FLAGS = --timing --trace -Wno-INITIALDLY -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNDRIVEN -Wno-TIMESCALEMOD -Wno-DECLFILENAME -Wno-UNOPTFLAT --cc --exe sim_main.cpp -CFLAGS "-DVM_PREFIX=V$(TOP)" -DSIMULATION --top-module $(TOP)

compile:
	@mkdir -p $(BUILD_DIR)/obj_dir
	cp sim_main.cpp $(BUILD_DIR)/obj_dir/
	verilator $(VERILATOR_FLAGS) -Mdir $(BUILD_DIR)/obj_dir $(RTL_SRC) $(TB_SRC)
	cd $(BUILD_DIR)/obj_dir && make -f V$(TOP).mk

run: compile
	./$(BUILD_DIR)/obj_dir/V$(TOP)

#---------------------------------------------------------------------
# VCS
#---------------------------------------------------------------------
else ifeq ($(SIM),vcs)

VCS_FLAGS = -sverilog -full64 -debug_access+all -kdb -timescale=1ns/1ps

compile: $(BUILD_DIR)/simv

$(BUILD_DIR)/simv: $(RTL_SRC) $(TB_SRC)
	@mkdir -p $(BUILD_DIR)
	vcs $(VCS_FLAGS) -o $@ $(RTL_SRC) $(TB_SRC)

run: compile
	cd $(BUILD_DIR) && ./simv

#---------------------------------------------------------------------
# Questa / ModelSim
#---------------------------------------------------------------------
else ifeq ($(SIM),questa)

WORK = work

compile:
	@mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && vlib $(WORK) && vmap work $(WORK)
	cd $(BUILD_DIR) && vlog -sv $(RTL_SRC) $(TB_SRC)

run: compile
	cd $(BUILD_DIR) && vsim -c $(TOP) -do "run -all; quit"

#---------------------------------------------------------------------
# Default / Unknown
#---------------------------------------------------------------------
else

compile:
	@echo "ERROR: Unknown simulator '$(SIM)'"
	@echo "Supported: iverilog, verilator, vcs, questa"
	@exit 1

run: compile

endif

clean:
	rm -rf $(BUILD_DIR) *.vcd

help:
	@echo "GEMM RTL Simulation"
	@echo ""
	@echo "Usage: make SIM=<simulator> TARGET=<target> [target]"
	@echo ""
	@echo "Simulators: iverilog (default), verilator, vcs, questa"
	@echo "Targets:    pe_cell (default), systolic_core"
	@echo "Targets:    compile, run, clean"
	@echo ""
	@echo "Examples:"
	@echo "  make SIM=iverilog TARGET=pe_cell run"
	@echo "  make SIM=verilator TARGET=systolic_core run"
	@echo "  make SIM=vcs TARGET=systolic_core run"
	@echo "  make clean"
