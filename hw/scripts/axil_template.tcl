# Regenerates AMD's AXI templates for comparison after a Vivado upgrade; not
# part of the build:
#   AXI4-Lite slave, the base of hw/rtl/npu_regs.v
#   AXI4 (full) master, the reference for hw/rtl/mem_bw.v's handshakes
#
#   vivado -mode batch -source hw/scripts/axil_template.tcl
#
# Output: build/axil_template/ip_repo/npu_axil_1_0/hdl/*_S00_AXI.v
#         build/axil_template/ip_repo/npu_axim_1_0/hdl/*_M00_AXI.v

set repo [file normalize [file dirname [info script]]/../..]
set out  $repo/build/axil_template
file mkdir $out
cd $out
create_project -in_memory -part xc7a200tfbg676-2
set p [create_peripheral user.org user npu_axil 1.0 -dir $out/ip_repo]
add_peripheral_interface S00_AXI -interface_mode slave -axi_type lite $p
set_property VALUE 16 [ipx::get_bus_parameters WIZ_NUM_REG -of_objects [ipx::get_bus_interfaces S00_AXI -of_objects $p]]
generate_peripheral -force $p
write_peripheral $p
puts "INFO: template in [glob $out/ip_repo/npu_axil_1_0/hdl/*_S00_AXI.v]"

set m [create_peripheral user.org user npu_axim 1.0 -dir $out/ip_repo]
add_peripheral_interface M00_AXI -interface_mode master -axi_type full $m
generate_peripheral -force $m
write_peripheral $m
puts "INFO: template in [glob $out/ip_repo/npu_axim_1_0/hdl/*_M00_AXI.v]"
