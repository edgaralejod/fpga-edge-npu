# Creates and generates the AMD IP cores used by the design.
#
# Only this script is kept in git: the generated IP output is AMD's and is
# rebuilt from these settings on every build.
#
# Usage (from build.tcl): source ip.tcl after setting ::ip_dir.

# --- PCIe DMA/Bridge Subsystem (XDMA) ----------------------------------------
# Gen2 x1: the FRDM-i.MX95 M.2 Key-M slot is a single PCIe 3.0 lane, and the
# Artix-7 GTP tops out at Gen2, so the link trains at 5 GT/s x1.
#
# BAR0: AXI-Lite master, the NPU's control registers (npu_regs).
# BAR1: XDMA's own DMA engine registers (descriptor rings, channel control).
#
# Vendor 10EE / device 7021 is the Xilinx default for Gen2 x1, which the stock
# Xilinx XDMA Linux driver (dma_ip_drivers) already lists in its ID table.
# Class 12 00 00 = "processing accelerator", what an NPU card should report.
create_ip -name xdma -vendor xilinx.com -library ip -module_name xdma_0 -dir $::ip_dir
set_property -dict [list \
  CONFIG.mode_selection             {Advanced} \
  CONFIG.functional_mode            {DMA} \
  CONFIG.pl_link_cap_max_link_width {X1} \
  CONFIG.pl_link_cap_max_link_speed {5.0_GT/s} \
  CONFIG.ref_clk_freq               {100_MHz} \
  CONFIG.axi_data_width             {64_bit} \
  CONFIG.axisten_freq               {125} \
  CONFIG.pcie_blk_locn              {X0Y0} \
  CONFIG.xdma_axi_intf_mm           {AXI_Memory_Mapped} \
  CONFIG.xdma_rnum_chnl             {1} \
  CONFIG.xdma_wnum_chnl             {1} \
  CONFIG.xdma_num_usr_irq           {1} \
  CONFIG.axilite_master_en          {true} \
  CONFIG.axilite_master_size        {64} \
  CONFIG.axilite_master_scale       {Kilobytes} \
  CONFIG.pciebar2axibar_axil_master {0x00000000} \
  CONFIG.cfg_mgmt_if                {false} \
  CONFIG.vendor_id                  {10EE} \
  CONFIG.pf0_device_id              {7021} \
  CONFIG.pf0_subsystem_vendor_id    {10EE} \
  CONFIG.pf0_subsystem_id           {0007} \
  CONFIG.pf0_Use_Class_Code_Lookup_Assistant {false} \
  CONFIG.pf0_class_code_base        {12} \
  CONFIG.pf0_class_code_sub         {00} \
  CONFIG.pf0_class_code_interface   {00} \
  CONFIG.pf0_class_code             {120000} \
] [get_ips xdma_0]

# --- On-card test memory -------------------------------------------------------
# 64 KiB of block RAM behind XDMA's AXI4 master. Phase 1 uses it as the DMA
# loopback target; later phases replace it with the DDR3 controller (MIG).
create_ip -name axi_bram_ctrl -vendor xilinx.com -library ip -module_name axi_bram_ctrl_0 -dir $::ip_dir
set_property -dict [list \
  CONFIG.PROTOCOL        {AXI4} \
  CONFIG.DATA_WIDTH      {64} \
  CONFIG.ID_WIDTH        {4} \
  CONFIG.MEM_DEPTH       {8192} \
  CONFIG.SINGLE_PORT_BRAM {1} \
  CONFIG.ECC_TYPE        {0} \
] [get_ips axi_bram_ctrl_0]

create_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name dma_bram_0 -dir $::ip_dir
set_property -dict [list \
  CONFIG.Memory_Type                 {Single_Port_RAM} \
  CONFIG.Use_BRAM_Block              {BRAM_Controller} \
  CONFIG.Write_Width_A               {64} \
  CONFIG.Read_Width_A                {64} \
  CONFIG.Write_Depth_A               {8192} \
  CONFIG.Enable_32bit_Address        {true} \
  CONFIG.Use_Byte_Write_Enable       {true} \
  CONFIG.Byte_Size                   {8} \
  CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
  CONFIG.Use_RSTA_Pin                {true} \
] [get_ips dma_bram_0]

set ips [get_ips]
generate_target {instantiation_template synthesis} $ips
# Out-of-context synthesis; the checkpoints are reused by later builds.
foreach ip $ips { synth_ip $ip }
