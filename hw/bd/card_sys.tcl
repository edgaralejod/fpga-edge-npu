# Block design "card_sys": the card's PCIe bridge, DDR3 memory system and
# debug cores. Everything written for the project (npu_regs, npu_cq with
# npu_mm, mem_bw) is Verilog in npu_top and connects to the ports below.
#
#   host ── PCIe Gen2 x1 ── axi_pcie bridge (AMD PG055)
#             BAR0 → AXI master ── SmartConnect (to AXI4-Lite) ── M_AXIL_REGS → npu_regs
#             AXI slave window ←── S_AXI_HOST ← npu_cq (commands, completions, copies)
#             MSI request      ←── npu_cq
#
#   S_AXI_NPU  (npu_cq card port, 64-bit, 125 MHz) ─┐
#   S_AXI_BW   (mem_bw, 512-bit, 100 MHz) ──────────┼─ SmartConnect ─ MIG ─ DDR3 SODIMM
#   JTAG-to-AXI (Vivado Tcl, 32-bit) ───────────────┘
#
# Debug cores, reached from Vivado's Hardware Manager over the JTAG cable:
#   System ILA on S_AXI_HOST (the engine's view of host memory), PCIe clock
#   System ILA on the MIG's AXI port, MIG clock; both with AXI protocol checkers
#   JTAG-to-AXI master into DDR3, VIO (MIG reset, calibration, lock) on dbg_clk
#
# Only this script is kept in git. build.tcl sources it when the generated
# design does not exist or this script changed: source card_sys.tcl after
# setting ::bd_dir.

proc ipdef {name} { lindex [lsort [get_ipdefs -all xilinx.com:ip:$name:*]] end }

create_bd_design -dir $::bd_dir card_sys

# --- PCIe bridge ---------------------------------------------------------------
# Gen2 x1 (the FRDM-i.MX95 slot is one lane; Gen2 is the Artix-7's limit).
# Device 10ee:ed10, class 12 00 00 (processing accelerator): the vendor ID is
# AMD's default for the core; ed10 is not an ID AMD assigned to anything, so
# AMD's stock drivers stay away and the project's fpga-npu driver binds.
# BAR0: 64 KiB at AXI address 0 (npu_regs). Slave window: AXI 0x8000_0000 to
# 0xFFFF_FFFF reaches host bus addresses 0 to 2 GiB (fixed translation; the
# driver uses a 31-bit DMA mask).
set pcie [create_bd_cell -type ip -vlnv [ipdef axi_pcie] pcie]
set_property -dict [list \
  CONFIG.INCLUDE_RC {PCI_Express_Endpoint_device} \
  CONFIG.MAX_LINK_SPEED {5.0_GT/s} CONFIG.NO_OF_LANES {X1} CONFIG.REF_CLK_FREQ {100_MHz} \
  CONFIG.VENDOR_ID {0x10EE} CONFIG.DEVICE_ID {0xED10} \
  CONFIG.SUBSYSTEM_VENDOR_ID {0x10EE} CONFIG.SUBSYSTEM_ID {0x0007} \
  CONFIG.BAR0_ENABLED {true} CONFIG.BAR0_TYPE {Memory} CONFIG.BAR0_SCALE {Kilobytes} CONFIG.BAR0_SIZE {64} \
  CONFIG.PCIEBAR2AXIBAR_0 {0x00000000} \
  CONFIG.AXIBAR_NUM {1} CONFIG.AXIBAR_0 {0x80000000} CONFIG.AXIBAR_HIGHADDR_0 {0xFFFFFFFF} \
  CONFIG.AXIBAR2PCIEBAR_0 {0x00000000} CONFIG.INCLUDE_BAROFFSET_REG {false} \
  CONFIG.M_AXI_DATA_WIDTH {64} CONFIG.S_AXI_DATA_WIDTH {64} \
] $pcie
set_property CONFIG.CLASS_CODE {0x120000} $pcie
puts "INFO: card_sys bridge id [get_property CONFIG.VENDOR_ID $pcie]:[get_property CONFIG.DEVICE_ID $pcie] class [get_property CONFIG.CLASS_CODE $pcie]"

make_bd_intf_pins_external [get_bd_intf_pins pcie/pcie_7x_mgt]
set_property NAME pcie_mgt [get_bd_intf_ports -of [get_bd_intf_nets -of [get_bd_intf_pins pcie/pcie_7x_mgt]]]
create_bd_port -dir I -type clk -freq_hz 100000000 pcie_refclk
connect_bd_net [get_bd_ports pcie_refclk] [get_bd_pins pcie/REFCLK]
create_bd_port -dir I -type rst pcie_perst_n
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports pcie_perst_n]

# PG055, "Resets": PERST# goes to a proc_sys_reset's aux_reset_in (active
# low), the bridge's mmcm_lock to dcm_locked; interconnect_aresetn drives the
# bridge, peripheral_aresetn the project's logic.
set rst_pcie [create_bd_cell -type ip -vlnv [ipdef proc_sys_reset] rst_pcie]
set_property CONFIG.C_AUX_RESET_HIGH {0} $rst_pcie
set one [create_bd_cell -type ip -vlnv [ipdef xlconstant] one]
set_property -dict [list CONFIG.CONST_VAL 1 CONFIG.CONST_WIDTH 1] $one
connect_bd_net [get_bd_pins pcie/axi_aclk_out]       [get_bd_pins rst_pcie/slowest_sync_clk]
connect_bd_net [get_bd_ports pcie_perst_n]           [get_bd_pins rst_pcie/aux_reset_in]
connect_bd_net [get_bd_pins one/dout]                [get_bd_pins rst_pcie/ext_reset_in]
connect_bd_net [get_bd_pins pcie/mmcm_lock]          [get_bd_pins rst_pcie/dcm_locked]
connect_bd_net [get_bd_pins rst_pcie/interconnect_aresetn] [get_bd_pins pcie/axi_aresetn]

create_bd_port -dir O -type clk pcie_aclk
create_bd_port -dir O -type rst pcie_aresetn
connect_bd_net [get_bd_pins pcie/axi_aclk_out]             [get_bd_ports pcie_aclk]
connect_bd_net [get_bd_pins rst_pcie/peripheral_aresetn]   [get_bd_ports pcie_aresetn]
create_bd_port -dir O pcie_link_up
connect_bd_net [get_bd_pins pcie/user_link_up] [get_bd_ports pcie_link_up]

# MSI: one-cycle request and grant (PG055, "MSI Interrupt"), one vector.
create_bd_port -dir I msi_request
create_bd_port -dir O msi_grant
create_bd_port -dir O msi_enable
connect_bd_net [get_bd_ports msi_request] [get_bd_pins pcie/INTX_MSI_Request]
connect_bd_net [get_bd_pins pcie/INTX_MSI_Grant] [get_bd_ports msi_grant]
connect_bd_net [get_bd_pins pcie/MSI_enable] [get_bd_ports msi_enable]
set zero5 [create_bd_cell -type ip -vlnv [ipdef xlconstant] zero5]
set_property -dict [list CONFIG.CONST_VAL 0 CONFIG.CONST_WIDTH 5] $zero5
connect_bd_net [get_bd_pins zero5/dout] [get_bd_pins pcie/MSI_Vector_Num]

# BAR0 → npu_regs (AXI4-Lite, 32-bit) through a SmartConnect that converts.
set m_axil [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXIL_REGS]
set_property -dict [list CONFIG.PROTOCOL AXI4LITE CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 32] $m_axil
set sc_regs [create_bd_cell -type ip -vlnv [ipdef smartconnect] sc_regs]
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1] $sc_regs
connect_bd_net [get_bd_pins pcie/axi_aclk_out]             [get_bd_pins sc_regs/aclk]
connect_bd_net [get_bd_pins rst_pcie/interconnect_aresetn] [get_bd_pins sc_regs/aresetn]
connect_bd_intf_net [get_bd_intf_pins pcie/M_AXI] [get_bd_intf_pins sc_regs/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_regs/M00_AXI] $m_axil

# npu_cq's host port → the bridge's slave window.
set s_axi_host [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_HOST]
set_property -dict [list \
  CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 64 CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 0 \
  CONFIG.HAS_REGION 0 CONFIG.HAS_QOS 0 CONFIG.HAS_CACHE 0 CONFIG.HAS_PROT 0 CONFIG.HAS_LOCK 0 \
  CONFIG.FREQ_HZ 125000000 \
] $s_axi_host
set sc_host [create_bd_cell -type ip -vlnv [ipdef smartconnect] sc_host]
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1] $sc_host
connect_bd_net [get_bd_pins pcie/axi_aclk_out]             [get_bd_pins sc_host/aclk]
connect_bd_net [get_bd_pins rst_pcie/interconnect_aresetn] [get_bd_pins sc_host/aresetn]
connect_bd_intf_net $s_axi_host [get_bd_intf_pins sc_host/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_host/M00_AXI] [get_bd_intf_pins pcie/S_AXI]

# npu_cq's card port → DDR3 (below).
set s_axi_npu [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_NPU]
set_property -dict [list \
  CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 64 CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 0 \
  CONFIG.HAS_REGION 0 CONFIG.HAS_QOS 0 CONFIG.HAS_CACHE 0 CONFIG.HAS_PROT 0 CONFIG.HAS_LOCK 0 \
  CONFIG.FREQ_HZ 125000000 \
] $s_axi_npu
set_property -dict [list CONFIG.ASSOCIATED_BUSIF {M_AXIL_REGS:S_AXI_HOST:S_AXI_NPU} CONFIG.ASSOCIATED_RESET pcie_aresetn] [get_bd_ports pcie_aclk]

# --- DDR3: MIG from the AC701 board preset (1 GiB SODIMM, 400 MHz, 4:1) ---------
# The preset sets the pinout, timing and the 200 MHz differential system clock
# (also used as the reference clock). AXI port: 512 bits at the 100 MHz ui_clk.
set mig [create_bd_cell -type ip -vlnv [ipdef mig_7series] mig_0]
apply_bd_automation -rule xilinx.com:bd_rule:mig_7series -config {Board_Interface "ddr3_sdram"} $mig

create_bd_port -dir I -type clk -freq_hz 78125000 dbg_clk
create_bd_port -dir I -type rst ddr_rst
set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_ports ddr_rst]

# Card-side masters in the MIG clock domain (mem_bw in npu_top).
set s_axi_bw [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_BW]
set_property -dict [list \
  CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 512 CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 0 \
  CONFIG.HAS_REGION 0 CONFIG.HAS_QOS 0 CONFIG.HAS_CACHE 1 CONFIG.HAS_PROT 1 CONFIG.HAS_LOCK 1 \
  CONFIG.FREQ_HZ 100000000 \
] $s_axi_bw
create_bd_port -dir O -type clk ui_clk
create_bd_port -dir O -type rst ui_aresetn
set_property -dict [list CONFIG.ASSOCIATED_BUSIF S_AXI_BW CONFIG.ASSOCIATED_RESET ui_aresetn] [get_bd_ports ui_clk]

create_bd_port -dir O ddr_calib_done
create_bd_port -dir O ddr_mmcm_locked

# --- MIG reset: board button (ddr_rst) or the VIO ----------------------------------
set vio [create_bd_cell -type ip -vlnv [ipdef vio] vio]
set_property -dict [list CONFIG.C_NUM_PROBE_IN 2 CONFIG.C_NUM_PROBE_OUT 1 CONFIG.C_EN_PROBE_IN_ACTIVITY 1] $vio
connect_bd_net [get_bd_ports dbg_clk] [get_bd_pins vio/clk]

set rst_or [create_bd_cell -type ip -vlnv [ipdef util_vector_logic] ddr_rst_or]
set_property -dict [list CONFIG.C_OPERATION or CONFIG.C_SIZE 1] $rst_or
connect_bd_net [get_bd_ports ddr_rst]      [get_bd_pins ddr_rst_or/Op1]
connect_bd_net [get_bd_pins vio/probe_out0] [get_bd_pins ddr_rst_or/Op2]
connect_bd_net [get_bd_pins ddr_rst_or/Res] [get_bd_pins mig_0/sys_rst]

connect_bd_net [get_bd_pins mig_0/init_calib_complete] [get_bd_ports ddr_calib_done] [get_bd_pins vio/probe_in0]
connect_bd_net [get_bd_pins mig_0/mmcm_locked]         [get_bd_ports ddr_mmcm_locked] [get_bd_pins vio/probe_in1]

# --- AXI reset in the MIG clock domain -------------------------------------------
# ext_reset_in takes its polarity (active high) from ui_clk_sync_rst.
set rst_ui [create_bd_cell -type ip -vlnv [ipdef proc_sys_reset] rst_ui]
connect_bd_net [get_bd_pins mig_0/ui_clk]          [get_bd_pins rst_ui/slowest_sync_clk]
connect_bd_net [get_bd_pins mig_0/ui_clk_sync_rst] [get_bd_pins rst_ui/ext_reset_in]
connect_bd_net [get_bd_pins mig_0/mmcm_locked]     [get_bd_pins rst_ui/dcm_locked]
connect_bd_net [get_bd_pins rst_ui/peripheral_aresetn] [get_bd_pins mig_0/aresetn]
connect_bd_net [get_bd_pins mig_0/ui_clk]               [get_bd_ports ui_clk]
connect_bd_net [get_bd_pins rst_ui/peripheral_aresetn] [get_bd_ports ui_aresetn]

# --- Interconnect: three masters, one memory ---------------------------------------
set jtag [create_bd_cell -type ip -vlnv [ipdef jtag_axi] jtag_axi]
set_property -dict [list CONFIG.PROTOCOL 0 CONFIG.M_AXI_DATA_WIDTH 32 CONFIG.M_AXI_ADDR_WIDTH 32] $jtag
connect_bd_net [get_bd_pins mig_0/ui_clk]               [get_bd_pins jtag_axi/aclk]
connect_bd_net [get_bd_pins rst_ui/peripheral_aresetn] [get_bd_pins jtag_axi/aresetn]

set sc [create_bd_cell -type ip -vlnv [ipdef smartconnect] sc]
set_property -dict [list CONFIG.NUM_SI 3 CONFIG.NUM_MI 1 CONFIG.NUM_CLKS 2] $sc
connect_bd_net [get_bd_pins mig_0/ui_clk]               [get_bd_pins sc/aclk]
connect_bd_net [get_bd_pins pcie/axi_aclk_out]          [get_bd_pins sc/aclk1]
connect_bd_net [get_bd_pins rst_ui/peripheral_aresetn] [get_bd_pins sc/aresetn]
connect_bd_intf_net $s_axi_npu                      [get_bd_intf_pins sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins jtag_axi/M_AXI] [get_bd_intf_pins sc/S01_AXI]
connect_bd_intf_net $s_axi_bw                       [get_bd_intf_pins sc/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins sc/M00_AXI]     [get_bd_intf_pins mig_0/S_AXI]

# --- System ILAs with AXI protocol checkers ---------------------------------------
# The checker flags handshake and ordering violations in the Hardware Manager,
# the class of bug that reached hardware in phase 1 (RVALID in the AR cycle).
# Vivado's debug automation creates one System ILA per clock domain.
set mon_host [get_bd_intf_nets -of $s_axi_host]
set mon_ddr  [get_bd_intf_nets -of [get_bd_intf_pins mig_0/S_AXI]]
set_property HDL_ATTRIBUTE.DEBUG true [list $mon_host $mon_ddr]
set axi_mon {AXI_R_ADDRESS "Data and Trigger" AXI_R_DATA "Data and Trigger" \
             AXI_W_ADDRESS "Data and Trigger" AXI_W_DATA "Data and Trigger" \
             AXI_W_RESPONSE "Data and Trigger" CLK_SRC "%s" SYSTEM_ILA "Auto" APC_EN "1"}
apply_bd_automation -rule xilinx.com:bd_rule:debug -dict [list \
  $mon_host [format $axi_mon /pcie/axi_aclk_out] \
  $mon_ddr  [format $axi_mon /mig_0/ui_clk] \
]
foreach ila [get_bd_cells -filter {VLNV =~ *system_ila*}] {
  set clk [get_bd_nets -of [get_bd_pins $ila/clk]]
  set depth [expr {[string match *pcie* $clk] ? 2048 : 1024}]
  set_property -dict [list CONFIG.C_DATA_DEPTH $depth CONFIG.C_EN_STRG_QUAL 1 CONFIG.C_ADV_TRIGGER true] $ila
  puts "INFO: card_sys ILA $ila on clock net $clk, depth $depth"
}

# --- Address map --------------------------------------------------------------------
# BAR0 (bridge M_AXI) → npu_regs at 0x0, 64 KiB.
assign_bd_address -offset 0x00000000 -range 64K -force \
  -target_address_space [get_bd_addr_spaces pcie/M_AXI] [get_bd_addr_segs M_AXIL_REGS/Reg]
# npu_cq's host port → the bridge window, 2 GiB at 0x8000_0000.
assign_bd_address -offset 0x80000000 -range 2G -force \
  -target_address_space [get_bd_addr_spaces S_AXI_HOST] [get_bd_addr_segs pcie/S_AXI/BAR0]
# Card masters → DDR3 at 0x0, 1 GiB.
foreach space {/S_AXI_NPU /jtag_axi/Data /S_AXI_BW} {
  assign_bd_address -offset 0x00000000 -range 1G -force \
    -target_address_space [get_bd_addr_spaces $space] [get_bd_addr_segs mig_0/memmap/memaddr]
}
foreach space {/pcie/M_AXI /S_AXI_HOST /S_AXI_NPU /jtag_axi/Data /S_AXI_BW} {
  foreach seg [get_bd_addr_segs -of [get_bd_addr_spaces $space]] {
    puts "INFO: card_sys address [get_property PATH $seg]: [get_property OFFSET $seg] + [get_property RANGE $seg]"
  }
}

validate_bd_design
save_bd_design
