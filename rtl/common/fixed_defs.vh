`ifndef FIXED_DEFS_VH
`define FIXED_DEFS_VH

`define ATTN_INT8_W               8
`define ATTN_INT16_W             16
`define ATTN_INT32_W             32

`define ATTN_INT8_MAX             8'sd127
`define ATTN_INT8_MIN            -8'sd128
`define ATTN_INT16_MAX           16'sd32767
`define ATTN_INT16_MIN          -16'sd32768
`define ATTN_SCORE_MIN          -16'sd32768
`define ATTN_BETA_ZERO           16'd0
`define ATTN_BETA_ONE            16'd32767

`define ATTN_ROUND_NEAREST        2'd0
`define ATTN_ROUND_ZERO           2'd1
`define ATTN_SAT_INT8             2'd0
`define ATTN_SAT_INT16            2'd1

`endif
