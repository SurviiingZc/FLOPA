`ifndef TB_FSDB_SVH
`define TB_FSDB_SVH

`ifdef TB_NO_FSDB
`define TB_FSDB_DUMP(DEFAULT_FILE, TOP_SCOPE)
`else
`define TB_FSDB_DUMP(DEFAULT_FILE, TOP_SCOPE) \
  string fsdb_file; \
  initial begin \
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) \
      fsdb_file = DEFAULT_FILE; \
    $fsdbDumpfile(fsdb_file); \
    $fsdbDumpvars(0, TOP_SCOPE, "+all"); \
    $fsdbDumpMDA(); \
  end
`endif

`endif
