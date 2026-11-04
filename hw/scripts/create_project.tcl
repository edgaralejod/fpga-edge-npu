# Creates a Vivado project from the repository's sources, for exploring the
# design in the GUI: the block design, IP settings, schematics, timing, the
# Hardware Manager with the debug probes.
#
#   vivado -mode batch -source hw/scripts/create_project.tcl -tclargs [project_dir]
#   vivado build/vivado_project/fpga-edge-npu.xpr
#
# The project is disposable (build/ is git-ignored): the sources of truth stay
# in hw/. Changes made in the GUI have to be carried back into hw/scripts/ip.tcl,
# hw/bd/card_sys.tcl, hw/rtl/ or hw/constr/ by hand. make bitstream remains the
# reference build; this project builds the same design with Vivado's runs.

set repo     [file normalize [file dirname [info script]]/../..]
set proj_dir [expr {[llength $argv] > 0 ? [file normalize [lindex $argv 0]] : "$repo/build/vivado_project"}]
set name     fpga-edge-npu
set part     xc7a200tfbg676-2

if {[file exists $proj_dir/$name.xpr]} {
  error "$proj_dir/$name.xpr exists; delete $proj_dir to recreate it"
}
file mkdir $proj_dir
cd $proj_dir

create_project $name $proj_dir -part $part
set_property board_part      xilinx.com:ac701:part0:1.4 [current_project]
set_property target_language Verilog [current_project]
set_property simulator_language Verilog [current_project]

# Standalone IP (none since phase 3; see ip.tcl), synthesized by the project's runs.
set ::ip_dir   $proj_dir/ip
file mkdir $::ip_dir
set ::ip_synth 0
source $repo/hw/scripts/ip.tcl

# Block design card_sys: PCIe bridge, DDR3, interconnect, ILAs, VIO, JTAG-to-AXI.
set ::bd_dir $proj_dir/bd
source $repo/hw/bd/card_sys.tcl
generate_target all [get_files card_sys.bd]

# RTL, read from the repository so edits in the GUI land in git.
add_files -norecurse [glob $repo/hw/rtl/*.v]
set_property top npu_top [current_fileset]
set_property generic {BUILD_ID=32'h00000000} [current_fileset]

# Constraints. The debug hub settings apply in implementation only.
add_files -fileset constrs_1 -norecurse [list $repo/hw/constr/ac701.xdc $repo/hw/constr/debug.xdc]
set_property USED_IN_SYNTHESIS false [get_files debug.xdc]
set_property target_constrs_file $repo/hw/constr/ac701.xdc [current_fileset -constrset]

# Simulation: the npu_regs testbench.
add_files -fileset sim_1 -norecurse [glob $repo/hw/sim/*.v]
set_property top tb_npu_regs [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# Same flow settings as build.tcl: physical optimization after placement, and
# the debug probes file written with the bitstream.
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "INFO: project ready: $proj_dir/$name.xpr"
close_project
