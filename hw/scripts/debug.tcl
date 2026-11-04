# Debug access to the card over JTAG, with or without a PCIe host.
#
#   vivado -mode batch -source hw/scripts/debug.tcl -tclargs <mode> [build_dir]
#
#   status        DDR3 calibration and MMCM lock (VIO), ILA and JTAG-AXI presence
#   ddr-reset     pulse the MIG reset from the VIO, then report status again
#   jtag-memtest  DDR3 test through the JTAG-to-AXI master: every address line
#                 (walking ones) and data patterns. Slow (JTAG), but needs
#                 nothing but the AC701 and its USB cable.
#
# Uses build/npu_top.ltx for probe names; it must match the loaded bitstream.
# For waveforms, open the same .ltx in the Hardware Manager GUI: hw_ila_1 and
# hw_ila_2 are the System ILAs on the PCIe-side and MIG-side AXI ports, each
# with an AXI protocol checker.

set mode      [expr {[llength $argv] > 0 ? [lindex $argv 0] : "status"}]
set repo      [file normalize [file dirname [info script]]/../..]
set build_dir [expr {[llength $argv] > 1 ? [file normalize [lindex $argv 1]] : "$repo/build"}]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
if {$dev eq ""} { error "no xc7a200t on the JTAG chain; check the AC701 USB cable and power" }
current_hw_device $dev
set_property PROBES.FILE      $build_dir/npu_top.ltx $dev
set_property FULL_PROBES.FILE $build_dir/npu_top.ltx $dev
refresh_hw_device $dev

set vio [lindex [get_hw_vios -of $dev] 0]
if {$vio eq ""} { error "no VIO found: is the loaded bitstream a phase 2 build, and does $build_dir/npu_top.ltx match it?" }

proc vio_in {vio pattern} {
  refresh_hw_vio $vio
  set p [lindex [get_hw_probes -of $vio -filter "NAME =~ *$pattern*"] 0]
  if {$p eq ""} { return "?" }
  return [get_property INPUT_VALUE $p]
}

proc report_status {dev vio} {
  set calib  [vio_in $vio calib]
  set locked [vio_in $vio mmcm_locked]
  puts "INFO: ddr calibrated $calib, ddr mmcm locked $locked"
  puts "INFO: ILAs: [get_hw_ilas -of $dev]"
  puts "INFO: JTAG-AXI masters: [get_hw_axis -of $dev]"
  return $calib
}

switch -- $mode {
  status { report_status $dev $vio }
  ddr-reset {
    set out [lindex [get_hw_probes -of $vio -filter {TYPE == vio_output}] 0]
    set_property OUTPUT_VALUE 1 $out; commit_hw_vio $out
    after 10
    set_property OUTPUT_VALUE 0 $out; commit_hw_vio $out
    puts "INFO: MIG reset pulsed; waiting for calibration"
    after 2000
    report_status $dev $vio
  }
  jtag-memtest {
    if {[report_status $dev $vio] ne "1"} { error "DDR3 not calibrated; see ddr-status" }
    set axi [lindex [get_hw_axis -of $dev] 0]
    reset_hw_axi $axi
    # Card addresses: 0, then one per address line (walking ones) up to 1 GiB.
    set addrs [list 0]
    for {set b 2} {$b < 30} {incr b} { lappend addrs [expr {1 << $b}] }
    set errors 0
    # Pattern word for an address. Not [expr {... ? ... : $pat}]: expr would
    # turn "00000000" into the number 0.
    proc word {pat a} {
      if {$pat eq "ADDR"} { return [format %08X [expr {$a ^ 0x13579BDF}]] }
      return $pat
    }
    foreach pat {A5A5A5A5 5A5A5A5A FFFFFFFF 00000000 ADDR} {
      # Write every address first, then read them all: an address line that is
      # stuck or shorted makes two addresses alias, and the earlier write is lost.
      foreach a $addrs {
        set data [word $pat $a]
        delete_hw_axi_txn -quiet [get_hw_axi_txns -quiet wr]
        create_hw_axi_txn wr $axi -type write -address [format %08X $a] -len 1 -data $data
        run_hw_axi -quiet [get_hw_axi_txns wr]
      }
      foreach a $addrs {
        set want [word $pat $a]
        delete_hw_axi_txn -quiet [get_hw_axi_txns -quiet rd]
        create_hw_axi_txn rd $axi -type read -address [format %08X $a] -len 1
        run_hw_axi -quiet [get_hw_axi_txns rd]
        set got [string toupper [get_property DATA [get_hw_axi_txns rd]]]
        if {$got ne $want} {
          incr errors
          if {$errors <= 10} { puts "ERROR: pattern $pat address 0x[format %08X $a]: wrote $want, read $got" }
        }
      }
    }
    puts "INFO: jtag-memtest: [llength $addrs] addresses x 5 patterns, $errors errors: [expr {$errors ? {FAIL} : {PASS}}]"
    if {$errors} { error "jtag-memtest failed" }
  }
  default { error "mode must be status, ddr-reset or jtag-memtest" }
}

close_hw_target
disconnect_hw_server
close_hw_manager
