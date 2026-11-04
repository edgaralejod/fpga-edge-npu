# Block design "card_mem": the card's DDR3 memory system and its debug cores.
#
#   XDMA AXI4 master (S_AXI_PCIE, 64-bit, 125 MHz) ─┐
#   mem_bw engine (S_AXI_BW, 512-bit, ui_clk) ──────┼─ SmartConnect ─ MIG ─ DDR3 SODIMM
#   JTAG-to-AXI master (Vivado Tcl, 32-bit) ────────┘
#
# Debug cores, all reached from Vivado's Hardware Manager over the JTAG cable:
#   ila_pcie  System ILA on S_AXI_PCIE, with AXI protocol checker (PCIe clock)
#   ila_ddr   System ILA on the MIG's AXI port, with protocol checker (MIG clock)
#   jtag_axi  reads and writes DDR3 without the PCIe host
#   vio       DDR reset request out; calibration and MMCM lock in. Runs on the
#             free-running user clock (dbg_clk) so it keeps working while the
#             MIG is held in reset.
#
# Only this script is kept in git. build.tcl sources it when the generated
# design does not exist yet: source card_mem.tcl after setting ::bd_dir.

proc ipdef {name} { lindex [lsort [get_ipdefs -all xilinx.com:ip:$name:*]] end }

create_bd_design -dir $::bd_dir card_mem

# --- DDR3: MIG from the AC701 board preset (1 GiB SODIMM, 400 MHz, 4:1) ---------
# The preset sets the pinout, timing and the 200 MHz differential system clock
# (also used as the reference clock). AXI port: 512 bits at the 100 MHz ui_clk.
set mig [create_bd_cell -type ip -vlnv [ipdef mig_7series] mig_0]
apply_bd_automation -rule xilinx.com:bd_rule:mig_7series -config {Board_Interface "ddr3_sdram"} $mig

# --- External ports ------------------------------------------------------------
set s_axi [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_PCIE]
set_property -dict [list \
  CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 64 CONFIG.ADDR_WIDTH 64 CONFIG.ID_WIDTH 4 \
  CONFIG.HAS_REGION 0 CONFIG.HAS_QOS 0 CONFIG.HAS_CACHE 1 CONFIG.HAS_PROT 1 CONFIG.HAS_LOCK 1 \
  CONFIG.FREQ_HZ 125000000 \
] $s_axi
create_bd_port -dir I -type clk -freq_hz 125000000 pcie_aclk
create_bd_port -dir I -type rst pcie_aresetn
set_property -dict [list CONFIG.ASSOCIATED_BUSIF S_AXI_PCIE CONFIG.ASSOCIATED_RESET pcie_aresetn] [get_bd_ports pcie_aclk]

create_bd_port -dir I -type clk -freq_hz 78125000 dbg_clk
create_bd_port -dir I -type rst ddr_rst
set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_ports ddr_rst]
# Card-side masters in the MIG clock domain (mem_bw in npu_top): their AXI
# port, the clock and reset they run on.
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

# --- Interconnect: two masters, one memory ----------------------------------------
set jtag [create_bd_cell -type ip -vlnv [ipdef jtag_axi] jtag_axi]
set_property -dict [list CONFIG.PROTOCOL 0 CONFIG.M_AXI_DATA_WIDTH 32 CONFIG.M_AXI_ADDR_WIDTH 32] $jtag
connect_bd_net [get_bd_pins mig_0/ui_clk]               [get_bd_pins jtag_axi/aclk]
connect_bd_net [get_bd_pins rst_ui/peripheral_aresetn] [get_bd_pins jtag_axi/aresetn]

set sc [create_bd_cell -type ip -vlnv [ipdef smartconnect] sc]
set_property -dict [list CONFIG.NUM_SI 3 CONFIG.NUM_MI 1 CONFIG.NUM_CLKS 2] $sc
connect_bd_net [get_bd_pins mig_0/ui_clk]               [get_bd_pins sc/aclk]
connect_bd_net [get_bd_ports pcie_aclk]                 [get_bd_pins sc/aclk1]
connect_bd_net [get_bd_pins rst_ui/peripheral_aresetn] [get_bd_pins sc/aresetn]
connect_bd_intf_net $s_axi                          [get_bd_intf_pins sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins jtag_axi/M_AXI] [get_bd_intf_pins sc/S01_AXI]
connect_bd_intf_net $s_axi_bw                       [get_bd_intf_pins sc/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins sc/M00_AXI]     [get_bd_intf_pins mig_0/S_AXI]

# --- System ILAs with AXI protocol checkers ---------------------------------------
# The checker flags handshake and ordering violations in the Hardware Manager,
# the class of bug that reached hardware in phase 1 (RVALID in the AR cycle).
# Vivado's debug automation creates one System ILA per clock domain.
set mon_pcie [get_bd_intf_nets -of $s_axi]
set mon_ddr  [get_bd_intf_nets -of [get_bd_intf_pins mig_0/S_AXI]]
set_property HDL_ATTRIBUTE.DEBUG true [list $mon_pcie $mon_ddr]
set axi_mon {AXI_R_ADDRESS "Data and Trigger" AXI_R_DATA "Data and Trigger" \
             AXI_W_ADDRESS "Data and Trigger" AXI_W_DATA "Data and Trigger" \
             AXI_W_RESPONSE "Data and Trigger" CLK_SRC "%s" SYSTEM_ILA "Auto" APC_EN "1"}
apply_bd_automation -rule xilinx.com:bd_rule:debug -dict [list \
  $mon_pcie [format $axi_mon /pcie_aclk] \
  $mon_ddr  [format $axi_mon /mig_0/ui_clk] \
]
foreach ila [get_bd_cells -filter {VLNV =~ *system_ila*}] {
  set clk [get_bd_nets -of [get_bd_pins $ila/clk]]
  set depth [expr {[string match *pcie* $clk] ? 2048 : 1024}]
  set_property -dict [list CONFIG.C_DATA_DEPTH $depth CONFIG.C_EN_STRG_QUAL 1 CONFIG.C_ADV_TRIGGER true] $ila
  puts "INFO: card_mem ILA $ila on clock net $clk, depth $depth"
}

# --- Address map: DDR3 at 0x0 for both masters -------------------------------------
# Card address = file offset on /dev/xdma0_h2c_0 and _c2h_0.
foreach space {/S_AXI_PCIE /jtag_axi/Data /S_AXI_BW} {
  assign_bd_address -offset 0x00000000 -range 1G -force \
    -target_address_space [get_bd_addr_spaces $space] [get_bd_addr_segs mig_0/memmap/memaddr]
}
foreach space {/S_AXI_PCIE /jtag_axi/Data /S_AXI_BW} {
  foreach seg [get_bd_addr_segs -of [get_bd_addr_spaces $space]] {
    puts "INFO: card_mem address [get_property PATH $seg]: [get_property OFFSET $seg] + [get_property RANGE $seg]"
  }
}

validate_bd_design
save_bd_design
