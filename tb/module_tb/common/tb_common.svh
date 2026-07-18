`ifndef TB_COMMON_SVH
`define TB_COMMON_SVH

`define TB_CHECK(COND, MSG) \
  if (!(COND)) begin \
    $error("[FAIL] %s", MSG); \
    errors = errors + 1; \
  end

`define TB_FINISH(NAME) \
  if (errors == 0) begin \
    $display("[PASS] %s", NAME); \
    $finish; \
  end else begin \
    $fatal(1, "[FAIL] %s: %0d checks failed", NAME, errors); \
  end

`define TB_TIMEOUT(CYCLES, NAME) \
  initial begin \
    repeat (CYCLES) @(posedge clk); \
    $fatal(1, "[TIMEOUT] %s", NAME); \
  end

`endif
