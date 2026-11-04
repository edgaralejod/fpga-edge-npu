# Standalone AMD IP cores, created from settings.
#
# Since phase 3 every AMD core (the axi_pcie bridge, the MIG, SmartConnects,
# resets and debug cores) lives in the card_sys block design,
# hw/bd/card_sys.tcl, so this script creates none. It stays as the place for
# a core that does not belong in the block design.
#
# Usage (from build.tcl or create_project.tcl): source ip.tcl after setting
# ::ip_dir; set ::ip_synth 0 to skip out-of-context synthesis.

set ips [get_ips -quiet]
if {[llength $ips]} {
  generate_target {instantiation_template synthesis} $ips
  if {![info exists ::ip_synth] || $::ip_synth} {
    foreach ip $ips { synth_ip $ip }
  }
}
