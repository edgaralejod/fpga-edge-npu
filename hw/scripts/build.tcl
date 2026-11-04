# Non-project build of the AC701 bitstream and SPI flash image.
#
#   vivado -mode batch -source hw/scripts/build.tcl -tclargs [build_dir] [build_id]
#
# Run from the repository root. Outputs land in build/ (git-ignored):
#   build/npu_top.bit, build/npu_top.mcs, build/reports/*.rpt

set repo      [file normalize [file dirname [info script]]/../..]
set build_dir [expr {[llength $argv] > 0 ? [file normalize [lindex $argv 0]] : "$repo/build"}]
set build_id  [expr {[llength $argv] > 1 ? [lindex $argv 1] : [clock format [clock seconds] -format "%y%m%d%H"]}]

set part xc7a200tfbg676-2
set ::ip_dir $build_dir/ip
file mkdir $build_dir/reports $::ip_dir

# Vivado keeps temporary files in ./.Xil/Vivado-<pid>-<host>. Work inside the
# build directory so another Vivado started in the repository root (in a
# container, possibly with the same PID) cannot remove them mid-build.
cd $build_dir

create_project -in_memory -part $part
set_property board_part xilinx.com:ac701:part0:1.4 [current_project]
set_property target_language Verilog [current_project]

# IP: reuse the generated cores when they exist, otherwise create them.
if {[file exists $::ip_dir/xdma_0/xdma_0.xci]} {
  foreach xci [glob $::ip_dir/*/*.xci] { read_ip $xci }
  set ips [get_ips]
  generate_target {synthesis} $ips
  foreach ip $ips {
    if {![file exists [file rootname [get_property IP_FILE $ip]].dcp]} { synth_ip $ip }
  }
} else {
  source $repo/hw/scripts/ip.tcl
}
# synth_ip reports failures without stopping the script; stop here instead of
# failing later with a misleading error.
foreach ip [get_ips] {
  if {![file exists [file rootname [get_property IP_FILE $ip]].dcp]} {
    error "IP $ip did not synthesize; see the synth_ip messages above"
  }
}

read_verilog [glob $repo/hw/rtl/*.v]
read_xdc     $repo/hw/constr/ac701.xdc

puts "INFO: build id 0x$build_id"
synth_design -top npu_top -part $part -generic BUILD_ID=32'h$build_id
report_utilization -file $build_dir/reports/synth_utilization.rpt

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 20 -file $build_dir/reports/timing_summary.rpt
report_utilization    -file $build_dir/reports/utilization.rpt
report_drc            -file $build_dir/reports/drc.rpt
report_io             -file $build_dir/reports/io.rpt

# Stop on timing failure: a bitstream that misses timing on the PCIe clocks
# trains intermittently, which is worse than no bitstream.
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "INFO: WNS $wns ns, WHS $whs ns"
if {$wns < 0 || $whs < 0} {
  error "timing not met (WNS $wns, WHS $whs); see $build_dir/reports/timing_summary.rpt"
}

write_checkpoint -force $build_dir/npu_top_routed.dcp
write_bitstream  -force $build_dir/npu_top.bit
write_cfgmem -force -format mcs -size 32 -interface SPIx4 \
  -loadbit "up 0x00000000 $build_dir/npu_top.bit" $build_dir/npu_top.mcs

puts "INFO: done: $build_dir/npu_top.bit, $build_dir/npu_top.mcs"
