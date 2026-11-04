# AC701 (HW-A7-AC701, XC7A200T-2FBG676C) constraints for npu_top.
#
# PCIe pin sources: AMD's PCIe 7-series core templates for the AC701
# (pcie_7x_v3_3 dev-board XDC) and the AC701 board file (Vivado board store,
# ac701 1.4) for the LEDs.

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

# --- Configuration -------------------------------------------------------------
# Quad-SPI boot from the on-board N25Q256 so the card is configured before the
# host releases PERST#. Compression keeps the configuration time short.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
