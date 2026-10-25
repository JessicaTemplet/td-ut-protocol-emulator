# cocotb testbench for the SHIPPED tt_um_dual Verilog (not the Cyclesim model).
#
#   make            RTL: src/tt_um_dual.v + the vendor SRAM behavioral model
#   make GATES=yes  gate level: the hardened netlist (copy it in first, see
#                   below) + std-cell/IO models + the vendor SRAM model
#
# Why this exists: the 20 Cyclesim suites simulate the behavioral Ram.create
# path; the tape-out netlist instead instantiates two RM_IHPSG13_1P_512x8
# hard macros per engine (Sram.create_512x16). Only this bench exercises that
# path (byte-lane wiring, single shared address port, write-through timing).
#
# Needs: iverilog, cocotb (see requirements.txt), and the CMOS5L PDK
# (PDK_ROOT; ../README.md says how to install it).

.DEFAULT_GOAL := sim
SIM ?= icarus
TOPLEVEL_LANG ?= verilog
PDK_ROOT ?= $(HOME)/ttsetup/pdk_cmos5l
SRC_DIR = $(PWD)/../src
CMOS5L = $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref

# the macro's behavioral model only has a functional body under FUNCTIONAL
COMPILE_ARGS += -DFUNCTIONAL -DSIM
VERILOG_SOURCES += $(CMOS5L)/sg13cmos5l_sram/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v
VERILOG_SOURCES += $(CMOS5L)/sg13cmos5l_sram/verilog/RM_IHPSG13_1P_512x8_c3_bm_bist.v

ifneq ($(GATES),yes)
SIM_BUILD = sim_build/rtl
VERILOG_SOURCES += $(SRC_DIR)/tt_um_dual.v
else
# Copy the hardened netlist here first, e.g.
#   cp ../tt_submission/tt_um_dual.v gate_level_netlist.v
# (what CI's gl_test uses too). Not runs/wokwi/final/pnl/*.pnl.v: that one
# has VDD/VSS pins on every cell, which these std-cell models do not declare.
SIM_BUILD = sim_build/gl
COMPILE_ARGS += -DGL_TEST
VERILOG_SOURCES += $(CMOS5L)/sg13cmos5l_io/verilog/sg13cmos5l_io.v
# the std-cell models instantiate UDPs (ihp_dff_r, ihp_mux2, ...) defined in
# their own file; the upstream template Makefile omits it
VERILOG_SOURCES += $(CMOS5L)/sg13cmos5l_stdcell/verilog/sg13cmos5l_udp.v
STDCELL_V = $(CMOS5L)/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v
ifeq ($(PATCH_STDCELL),yes)
# Stock iverilog (12.x) never drives the vendor flops' `delayed_*` nets (they
# come from $setuphold), so every flop stays X. TT's CI uses its own iverilog
# 13 fork and needs no patch; locally, simulate a copy with those nets tied.
STDCELL_V = $(PWD)/sim_build/stdcell_patched.v
$(STDCELL_V): $(CMOS5L)/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v patch_stdcell.py
	mkdir -p sim_build && python3 patch_stdcell.py $< $@
endif
VERILOG_SOURCES += $(STDCELL_V)
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
endif

VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb
# cocotb 2.x reads COCOTB_TEST_MODULES, 1.x (what the TT CI action installs
# unless test/requirements.txt exists) reads MODULE; test.py works under both.
COCOTB_TEST_MODULES = test
MODULE = test

include $(shell cocotb-config --makefiles)/Makefile.sim
