# AC701 (HW-A7-AC701, XC7A200T-2FBG676C) constraints for npu_top.
#
# PCIe pin sources: AMD's PCIe 7-series core templates for the AC701
# (pcie_7x_v3_3 dev-board XDC) and the AC701 board file (Vivado board store,
# ac701 1.4) for the LEDs. UG952 v1.4 for the user clock and CPU_RESET.
#
# The DDR3 pins and the 200 MHz system clock (R3/P3) are constrained by the
# MIG's own XDC inside the card_mem block design (AC701 board preset).

# --- PCIe ----------------------------------------------------------------------
# Reference clock: 100 MHz from the host on the edge connector, GTP quad 213.
# Placing the IBUFDS_GTE2 places the refclk pins with it.
set_property LOC IBUFDS_GTE2_X0Y2 [get_cells refclk_ibuf]
create_clock -name pcie_refclk -period 10.000 [get_ports pcie_refclk_p]

# PERST#: from the host, active low.
set_property PACKAGE_PIN M20 [get_ports pcie_perst_n]
set_property IOSTANDARD LVCMOS33 [get_ports pcie_perst_n]
set_property PULLUP true [get_ports pcie_perst_n]
set_false_path -from [get_ports pcie_perst_n]

# Lane 0 is placed by the XDMA core's own constraints (GTPE2_CHANNEL_X0Y7,
# PCIE_X0Y0), which match the AC701 edge connector's lane 0.

# --- LEDs ----------------------------------------------------------------------
set_property PACKAGE_PIN M26 [get_ports {led[0]}]
set_property PACKAGE_PIN T24 [get_ports {led[1]}]
set_property PACKAGE_PIN T25 [get_ports {led[2]}]
set_property PACKAGE_PIN R26 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
set_false_path -to [get_ports {led[*]}]

# --- DDR3 support ----------------------------------------------------------------
# CPU_RESET pushbutton (SW8), active high, bank 34 at 1.5 V: resets the MIG.
set_property PACKAGE_PIN U4 [get_ports cpu_reset]
set_property IOSTANDARD LVCMOS15 [get_ports cpu_reset]
set_false_path -from [get_ports cpu_reset]

# DDR status into npu_regs crosses from the MIG clock through two flops.
set_false_path -to [get_cells -hier -filter {NAME =~ *regs/ddr_sync1_reg*}]

# mem_bw crosses between the PCIe user clock and the MIG clock with toggles
# through two flops; the settings and results it moves are held steady around
# each toggle (see hw/rtl/mem_bw.v), so they have no timing relationship.
set_false_path -to [get_cells -hier -filter {NAME =~ *bw/m_start_sync_reg[0]*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *bw/ctl_done_sync_reg[0]*}]
set_false_path -from [get_cells -hier -filter {NAME =~ *regs/bw_* || NAME =~ *bw/ctl_start_tgl_reg*}] \
               -to   [get_cells -hier -filter {NAME =~ *bw/m_*}]
set_false_path -from [get_cells -hier -filter {NAME =~ *bw/m_cycles_reg* || NAME =~ *bw/m_mismatches_reg* || NAME =~ *bw/m_errors_reg* || NAME =~ *bw/m_done_tgl_reg*}] \
               -to   [get_cells -hier -filter {NAME =~ *bw/ctl_*}]

# --- Debug ---------------------------------------------------------------------
# Si570 user clock, 156.25 MHz at power-up (3.3 V LVDS into bank 14; the bank
# runs at 3.3 V, so no internal termination). An MMCM in npu_top divides it to
# 78.125 MHz for the VIO and the debug hub, which therefore work without a
# PCIe host and with the MIG in reset.
set_property PACKAGE_PIN M21 [get_ports user_clk_p]
set_property PACKAGE_PIN M22 [get_ports user_clk_n]
set_property IOSTANDARD LVDS_25 [get_ports {user_clk_p user_clk_n}]
set_property DIFF_TERM FALSE [get_ports {user_clk_p user_clk_n}]
create_clock -name user_clk -period 6.400 [get_ports user_clk_p]

# The VIO samples the MIG's calibration flag asynchronously in the debug clock
# domain; no timing relationship. (mmcm_locked, its other input, comes straight
# from an MMCM pin and is not timed.)
set_false_path -from [get_cells -hier -filter {NAME =~ *u_ddr_calib_top/init_calib_complete_reg}] \
               -to   [get_clocks -of_objects [get_pins dbg_clk_bufg/O]]

# --- Configuration -------------------------------------------------------------
# Quad-SPI boot from the on-board N25Q256 so the card is configured before the
# host releases PERST#. Compression keeps the configuration time short.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
