# fpga-edge-npu build entry points. Run from the repository root.
#
#   make bitstream   FPGA bitstream and SPI flash image (Vivado 2025.2)
#   make sim         self-checking XSim testbenches
#   make tools       npu-ctl host tool (CC=aarch64-linux-gnu-gcc for the i.MX95)
#   make program     load the bitstream over JTAG
#   make flash       write the SPI flash over JTAG
#   make status      mode pins and DONE, read over JTAG
#   make clean       remove build/ and the host tool
#
# Vivado must be on PATH (source <install>/2025.2/Vivado/settings64.sh). When
# Vivado runs in a container, set XRUN to the command prefix that runs a
# program inside it, e.g. XRUN="fpga run 2025.2 --". The repository must be
# visible at the same path inside the container.

XRUN    ?=
VIVADO  ?= vivado
BUILD   := build
TESTS   := tb_npu_regs

bitstream:
	mkdir -p $(BUILD)
	$(XRUN) $(VIVADO) -mode batch -nojournal -log $(BUILD)/vivado.log \
	  -source hw/scripts/build.tcl -tclargs $(BUILD)

program:
	$(XRUN) $(VIVADO) -mode batch -nojournal -nolog \
	  -source hw/scripts/program.tcl -tclargs jtag $(BUILD)

flash:
	$(XRUN) $(VIVADO) -mode batch -nojournal -nolog \
	  -source hw/scripts/program.tcl -tclargs flash $(BUILD)

status:
	$(XRUN) $(VIVADO) -mode batch -nojournal -nolog \
	  -source hw/scripts/program.tcl -tclargs status

sim:
	@for tb in $(TESTS); do $(XRUN) hw/sim/run_xsim.sh $$tb || exit 1; done

tools:
	$(MAKE) -C sw/tools

clean:
	rm -rf $(BUILD) .Xil
	$(MAKE) -C sw/tools clean

.PHONY: bitstream program flash status sim tools clean
