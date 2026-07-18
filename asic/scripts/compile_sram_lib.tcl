if {![info exists env(FA_DC_LIB)]} {
  error "FA_DC_LIB is not set"
}

set output_dir [file normalize $env(FA_DC_LIB)]
file mkdir $output_dir

if {[info exists env(FA_SRAM_LIB_FILE)]} {
  set sram_lib_file [file normalize $env(FA_SRAM_LIB_FILE)]
} else {
  set sram_lib_file "/data/public/SRAM/uhdsp_256x8m4s/NLDM/uhdsp_256x8m4s_tt0p9v25c.lib"
}
if {[info exists env(FA_SRAM_DB_FILE)]} {
  set sram_db_file [file normalize $env(FA_SRAM_DB_FILE)]
} else {
  set sram_db_file [file join $output_dir uhdsp_256x8m4s_tt0p9v25c.db]
}
if {[info exists env(FA_SRAM_LIB_NAME)]} {
  set sram_lib_name $env(FA_SRAM_LIB_NAME)
} else {
  set sram_lib_name uhdsp_256x8m4s_tt0p9v25c
}

read_lib $sram_lib_file
write_lib $sram_lib_name -format db -output $sram_db_file

if {![file exists $sram_db_file]} {
  puts stderr "ERROR: failed to create SRAM DB: $sram_db_file"
  exit 2
}

exit
