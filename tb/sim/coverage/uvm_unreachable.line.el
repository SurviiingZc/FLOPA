// W-RTL-002: scheduler fallback paths blocked by accel_regfile validation.
// CHECKSUM: "791419885 3095293643"
MODULE: accel_scheduler
Block 31 "3941328138" "next_state_w = 4'd8;"
Block 63 "1799624472" "error_o <= 1'b1;"

// W-MATH-001: interpolation is bounded by its ordered positive endpoints.
// CHECKSUM: "3978070448 4179447488"
MODULE: pwl_exp_unit
Block 26 "414141713" "y_o <= 16'b0;"
Block 28 "1511845319" "y_o <= 16'd32767;"

// W-RTL-001/003/004: fixed parameters, corrupt state, fixed latency ordering.
// CHECKSUM: "3295607406 520669638"
MODULE: attention_accel_top
Block 2 "1574277866" "$fatal(1, \"physical array dimensions must equal CACHE_LANES\");"
Block 5 "3473373025" "$fatal(1, \"physical Q/K/V array path must remain native INT8\");"
Block 8 "4216352303" "$fatal(1, \"ARRAY_ROWS must be divisible by STRIPE_ROWS\");"
Block 62 "4080253863" "pv_flow_state_q <= PV_FLOW_WAIT_L;"
Block 67 "2118855190" "if (l_update_done_q)"
Block 68 "4007226613" "if (tile_last_w)"
Block 69 "433025818" "norm_stripe_q <= {STRIPE_IDX_W {1'b0}};"
Block 70 "536675817" "pv_flow_state_q <= PV_FLOW_COMPLETE;"
Block 85 "2951100588" "pv_flow_state_q <= PV_FLOW_IDLE;"
