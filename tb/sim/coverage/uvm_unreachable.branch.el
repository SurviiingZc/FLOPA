// W-MATH-001: ordered positive PWL endpoints cannot underflow or exceed Q15.
// CHECKSUM: "3978070448 2052665677"
MODULE: pwl_exp_unit
Branch 1 "1487368559" "(!rst_n)" (6) "(!rst_n) 0,-,-,1,0,1,-"
Branch 1 "1487368559" "(!rst_n)" (7) "(!rst_n) 0,-,-,1,0,0,1"

// W-RTL-001/003/004: fixed parameters, corrupt state, fixed latency ordering.
// CHECKSUM: "3295607406 3848233928"
MODULE: attention_accel_top
Branch 3 "3924059574" "((ARRAY_ROWS != CACHE_LANES) || (ARRAY_COLS != CACHE_LANES))" (0) "((ARRAY_ROWS != CACHE_LANES) || (ARRAY_COLS != CACHE_LANES)) 1"
Branch 4 "1889436687" "(ARRAY_DATA_W != 8)" (0) "(ARRAY_DATA_W != 8) 1"
Branch 5 "896142848" "((ARRAY_ROWS % STRIPE_ROWS) != 0)" (0) "((ARRAY_ROWS % STRIPE_ROWS) != 0) 1"
Branch 8 "2984954529" "(!rst_n)" (17) "(!rst_n) 0,0,-,-,-,-,-,PV_FLOW_WAIT_L ,-,-,-,-,-,1,1,-,-,-,-,-"
Branch 8 "2984954529" "(!rst_n)" (18) "(!rst_n) 0,0,-,-,-,-,-,PV_FLOW_WAIT_L ,-,-,-,-,-,1,0,-,-,-,-,-"
Branch 8 "2984954529" "(!rst_n)" (19) "(!rst_n) 0,0,-,-,-,-,-,PV_FLOW_WAIT_L ,-,-,-,-,-,0,-,-,-,-,-,-"
Branch 8 "2984954529" "(!rst_n)" (28) "(!rst_n) 0,0,-,-,-,-,-,default,-,-,-,-,-,-,-,-,-,-,-,-"

// W-RTL-003: legal stimulus cannot corrupt scheduler state encoding.
// CHECKSUM: "791419885 223854363"
MODULE: accel_scheduler
Branch 1 "953421796" "state_o" (21) "state_o default,-,-,-,-,-,-,-,-,-,-,-,-"
