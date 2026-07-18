`ifndef ATTENTION_DEFINES_VH
`define ATTENTION_DEFINES_VH

`define ATTN_DATA_W               8
`define ATTN_ARRAY_DATA_W        16
`define ATTN_ACC_W               32
`define ATTN_SCORE_W             32
`define ATTN_SCORE_FIXED_W       16
`define ATTN_SCORE_FRAC           8
`define ATTN_BETA_W              16
`define ATTN_BETA_FRAC           15
`define ATTN_LSE_W               32
`define ATTN_OUT_W                8

`define ATTN_ARRAY_ROWS          32
`define ATTN_ARRAY_COLS          32
`define ATTN_ARRAY_STRIPE_ROWS   8
`define ATTN_SOFTMAX_LANES       32
`define ATTN_HEAD_DIM            64
`define ATTN_TILE_Q              32
`define ATTN_TILE_K              32
`define ATTN_NUM_BANKS           16
`define ATTN_CACHE_ADDR_W        10

`define ATTN_AXI_ADDR_W          32
`define ATTN_AXI_DATA_W         128
`define ATTN_CACHE_WORD_W       256
`define ATTN_AXI_LITE_DATA_W     32
`define ATTN_AXI_LITE_STRB_W      4

`define ATTN_DEFAULT_HEAD_DIM    8'd64
`define ATTN_DEFAULT_NUM_HEADS   8'd9
`define ATTN_DEFAULT_TILE_Q      8'd32
`define ATTN_DEFAULT_TILE_K      8'd32

`define ATTN_MODESEL_MHA          1'b0
`define ATTN_MODESEL_GQA          1'b1

`define ATTN_CACHE_Q              2'd0
`define ATTN_CACHE_K              2'd1
`define ATTN_CACHE_V              2'd2

`define ATTN_PE_MAC_INT8          3'd0
`define ATTN_PE_SUB               3'd1
`define ATTN_PE_MAX_PASS          3'd2
`define ATTN_PE_ADD_PASS          3'd3
`define ATTN_PE_SCALE             3'd4
`define ATTN_PE_HOLD              3'd5

`define ATTN_ARRAY_PHASE_IDLE     2'd0
`define ATTN_ARRAY_PHASE_QK       2'd1
`define ATTN_ARRAY_PHASE_PV       2'd2

`define ATTN_REDUCE_MAX           1'b0
`define ATTN_REDUCE_SUM           1'b1

`define ATTN_STATE_IDLE           4'd0
`define ATTN_STATE_LOAD_Q         4'd1
`define ATTN_STATE_LOAD_KV        4'd2
`define ATTN_STATE_QK             4'd3
`define ATTN_STATE_SOFTMAX        4'd4
`define ATTN_STATE_PV             4'd5
`define ATTN_STATE_WRITEBACK      4'd6
`define ATTN_STATE_DONE           4'd7
`define ATTN_STATE_ERROR          4'd8

`define ATTN_ERR_NONE             4'd0
`define ATTN_ERR_BAD_CFG          4'd1
`define ATTN_ERR_BUS              4'd2
`define ATTN_ERR_PROTOCOL         4'd3
`define ATTN_ERR_ALIGNMENT        4'd4
`define ATTN_ERR_OVERFLOW         4'd5
`define ATTN_ERR_FATAL            4'd15

`define ATTN_REG_CONTROL          12'h000
`define ATTN_REG_STATUS           12'h004
`define ATTN_REG_ERROR_CODE       12'h008
`define ATTN_REG_VERSION          12'h00c
`define ATTN_REG_Q_BASE_LO        12'h010
`define ATTN_REG_Q_BASE_HI        12'h014
`define ATTN_REG_K_BASE_LO        12'h018
`define ATTN_REG_K_BASE_HI        12'h01c
`define ATTN_REG_V_BASE_LO        12'h020
`define ATTN_REG_V_BASE_HI        12'h024
`define ATTN_REG_O_BASE_LO        12'h028
`define ATTN_REG_O_BASE_HI        12'h02c
`define ATTN_REG_Q_STRIDE         12'h030
`define ATTN_REG_K_STRIDE         12'h034
`define ATTN_REG_V_STRIDE         12'h038
`define ATTN_REG_O_STRIDE         12'h03c
`define ATTN_REG_SEQ_Q            12'h040
`define ATTN_REG_SEQ_KV           12'h044
`define ATTN_REG_NUM_Q_HEADS      12'h048
`define ATTN_REG_NUM_KV_HEADS     12'h04c
`define ATTN_REG_HEAD_DIM         12'h050
`define ATTN_REG_TILE_Q           12'h054
`define ATTN_REG_TILE_K           12'h058
`define ATTN_REG_MODE             12'h05c
`define ATTN_REG_SCORE_SCALE      12'h060
`define ATTN_REG_VALUE_SCALE      12'h064
`define ATTN_REG_OUT_SCALE        12'h068
`define ATTN_REG_MASK_CFG         12'h06c
`define ATTN_REG_PERF_CTRL        12'h070
`define ATTN_REG_PERF_CYCLES_LO   12'h074
`define ATTN_REG_PERF_CYCLES_HI   12'h078
`define ATTN_REG_PERF_STALL_LO    12'h07c
`define ATTN_REG_PERF_STALL_HI    12'h080
`define ATTN_REG_PERF_MAC_LO      12'h084
`define ATTN_REG_PERF_MAC_HI      12'h088
`define ATTN_REG_PERF_TILES       12'h08c

`define ATTN_CTRL_START_BIT        0
`define ATTN_CTRL_SOFT_RESET_BIT   1
`define ATTN_CTRL_CLEAR_DONE_BIT   2
`define ATTN_CTRL_CLEAR_ERROR_BIT  3
`define ATTN_CTRL_MODE_SEL_BIT     4
`define ATTN_CTRL_CAUSAL_EN_BIT    5
`define ATTN_CTRL_PREFILL_EN_BIT   6
`define ATTN_CTRL_DECODE_EN_BIT    7

`endif
