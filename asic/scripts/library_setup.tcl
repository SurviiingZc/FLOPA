foreach required_variable {FA_ROOT FA_STD_DB FA_SRAM_DB} {
  if {![info exists env($required_variable)]} {
    error "$required_variable is not set"
  }
}

set root_dir [file normalize $env(FA_ROOT)]
set std_db [file normalize $env(FA_STD_DB)]
set sram_db [file normalize $env(FA_SRAM_DB)]

foreach required_file [list $std_db $sram_db] {
  if {![file isfile $required_file]} {
    error "required timing library does not exist: $required_file"
  }
}

set_app_var search_path [concat [get_app_var search_path] [list \
  [file join $root_dir rtl common] \
  [file dirname $std_db] \
  [file dirname $sram_db]]]
set_app_var target_library [list $std_db]
set_app_var synthetic_library [list dw_foundation.sldb]
set_app_var link_library [list "*" $std_db $sram_db dw_foundation.sldb]

puts "INFO: standard-cell target library: $std_db"
puts "INFO: SRAM link library: $sram_db"
puts "INFO: DesignWare synthetic library: dw_foundation.sldb"
