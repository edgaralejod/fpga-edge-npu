# Debug hub settings, applied in implementation only (build.tcl), after the
# hub exists. The hub connects Vivado's Hardware Manager to the ILAs, the VIO
# and the JTAG-to-AXI master; clocking it from the free-running user clock
# keeps all of them reachable when the PCIe clock or the MIG clock is absent.
set_property C_CLK_INPUT_FREQ_HZ 78125000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets dbg_clk]
