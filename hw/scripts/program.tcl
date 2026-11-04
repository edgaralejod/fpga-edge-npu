# Programs the AC701 over JTAG.
#
#   vivado -mode batch -source hw/scripts/program.tcl -tclargs jtag  [build_dir]
#   vivado -mode batch -source hw/scripts/program.tcl -tclargs flash [build_dir]
#   vivado -mode batch -source hw/scripts/program.tcl -tclargs status
#
# jtag:  load build/npu_top.bit into the FPGA now (lost at power-off; the host
#        must be rebooted afterwards to enumerate the card).
# flash: write build/npu_top.mcs to the on-board SPI flash, so the FPGA
#        configures itself at power-on before the host boots. Booting from
#        the flash afterwards needs mode switch SW1 at 001 (master SPI).
# status: print the mode pins and DONE without changing anything.
#
# The AC701 carries a Micron N25Q256 (JEDEC ID 20 BA 19). Vivado 2025.2 no
# longer lists that part; its successor MT25QL256 uses the same commands and
# programs it correctly (checked on hardware, 2026-11-04).

set mode      [expr {[llength $argv] > 0 ? [lindex $argv 0] : "jtag"}]
set repo      [file normalize [file dirname [info script]]/../..]
set build_dir [expr {[llength $argv] > 1 ? [file normalize [lindex $argv 1]] : "$repo/build"}]
set flash_part mt25ql256-spi-x1_x2_x4

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xc7a200t*] 0]
if {$dev eq ""} { error "no xc7a200t on the JTAG chain; check the AC701 USB cable and power" }
current_hw_device $dev

switch -- $mode {
  jtag {
    set_property PROGRAM.FILE $build_dir/npu_top.bit $dev
    program_hw_devices $dev
    puts "INFO: FPGA programmed from $build_dir/npu_top.bit"
  }
  flash {
    create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts $flash_part] 0]
    set mem [get_property PROGRAM.HW_CFGMEM $dev]
    set_property PROGRAM.ADDRESS_RANGE  {use_file} $mem
    set_property PROGRAM.FILES          [list $build_dir/npu_top.mcs] $mem
    set_property PROGRAM.BLANK_CHECK    0 $mem
    set_property PROGRAM.ERASE          1 $mem
    set_property PROGRAM.CFG_PROGRAM    1 $mem
    set_property PROGRAM.VERIFY         1 $mem
    set_property PROGRAM.CHECKSUM       0 $mem
    # Load the flash-programming helper bitstream, then write and verify.
    create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
    program_hw_devices $dev
    refresh_hw_device $dev
    program_hw_cfgmem -hw_cfgmem $mem
    # Reconfigure from the freshly written flash. This only works with the
    # mode pins at master SPI; say so instead of leaving a bare error.
    refresh_hw_device -update_hw_probes false $dev
    if {[get_property {REGISTER.CONFIG_STATUS.BIT10_MODE_PIN_M[2]} $dev] ne "0" ||
        [get_property {REGISTER.CONFIG_STATUS.BIT08_MODE_PIN_M[0]} $dev] ne "1"} {
      error "flash written and verified, but mode switch SW1 is not at 001 (master SPI); set it and power-cycle the AC701"
    }
    boot_hw_device $dev
    puts "INFO: SPI flash written and verified from $build_dir/npu_top.mcs; FPGA rebooted from flash"
  }
  status {
    refresh_hw_device -update_hw_probes false $dev
    set m [string cat \
      [get_property {REGISTER.CONFIG_STATUS.BIT10_MODE_PIN_M[2]} $dev] \
      [get_property {REGISTER.CONFIG_STATUS.BIT09_MODE_PIN_M[1]} $dev] \
      [get_property {REGISTER.CONFIG_STATUS.BIT08_MODE_PIN_M[0]} $dev]]
    puts "INFO: mode pins M\[2:0\] = $m (001 master SPI flash, 101 JTAG)"
    puts "INFO: DONE = [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev], end of startup = [get_property {REGISTER.CONFIG_STATUS.BIT04_END_OF_STARTUP_(EOS)_STATUS} $dev]"
  }
  default { error "mode must be jtag, flash or status" }
}

close_hw_target
disconnect_hw_server
close_hw_manager
