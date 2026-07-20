`timescale 1ns/1ps

// Persistent row-banked O storage for one physical stripe. The full feature ID
// directly addresses O[row,d], allowing O_old[:,d] to be read just in time for
// V[:,d] and O_new[row,d] to be written back without row/group preload buffers.
module o_accumulator_bank #(
  parameter integer ROWS = 8,
  parameter integer HEAD_DIM = 64,
  parameter integer GROUP_SIZE = 32,
  parameter integer DATA_W = 32,
  parameter integer ROW_IDX_W = (ROWS < 2) ? 1 : $clog2(ROWS),
  parameter integer FEATURE_IDX_W = (HEAD_DIM < 2) ? 1 : $clog2(HEAD_DIM)
)(
  input                              clk,
  input                              rst_n,
  input                              clear_i,
  input                              rd_en_i,
  input      [FEATURE_IDX_W-1:0]     rd_feature_i,
  output reg                         rd_valid_o,
  output reg [ROWS*DATA_W-1:0]       rd_data_o,
  input      [ROWS-1:0]              wr_valid_i,
  input      [ROWS*FEATURE_IDX_W-1:0] wr_feature_i,
  input      [ROWS*DATA_W-1:0]       wr_data_i
);

  // High feature bits select a physical SRAM group; low bits select the word
  // inside that group. Groups are storage banks, not serial compute phases.
  localparam integer GROUPS = (HEAD_DIM + GROUP_SIZE - 1) / GROUP_SIZE;
  localparam integer GROUP_IDX_W = (GROUPS < 2) ? 1 : $clog2(GROUPS);
  localparam integer GROUP_ADDR_W = (GROUP_SIZE < 2) ? 1 : $clog2(GROUP_SIZE);
  integer row;

`ifndef SYNTHESIS
  initial begin
    if ((1 << GROUP_ADDR_W) != GROUP_SIZE)
      $fatal(1, "o_accumulator_bank GROUP_SIZE must be a power of two");
    if (GROUP_SIZE > 256)
      $fatal(1, "o_accumulator_bank GROUP_SIZE exceeds SRAM macro depth");
    if (DATA_W % 8 != 0)
      $fatal(1, "o_accumulator_bank DATA_W must be byte aligned");
  end

  // Each row/group is single-port in ASIC. Reject any schedule that reads and
  // writes the same physical feature group in one cycle, even at different words.
  always @(posedge clk) begin
    if (rst_n && rd_en_i) begin
      for (row = 0; row < ROWS; row = row + 1)
        if (wr_valid_i[row] &&
            (wr_feature_i[row*FEATURE_IDX_W +: FEATURE_IDX_W] >> GROUP_ADDR_W) ==
            (rd_feature_i >> GROUP_ADDR_W))
          $fatal(1, "o_accumulator_bank single-port feature-group collision");
    end
  end
`endif

`ifdef ATTN_ASIC
  wire [DATA_W-1:0] macro_q_w [0:ROWS-1][0:GROUPS-1];
  reg [GROUP_IDX_W-1:0] rd_group_q;

  // ASIC organization is [row][feature group], so all stripe rows can access the
  // same feature in parallel while unused groups remain clock/enable gated.
  generate
    genvar macro_row;
    genvar macro_group;
    for (macro_row = 0; macro_row < ROWS; macro_row = macro_row + 1) begin : g_row
      wire [FEATURE_IDX_W-1:0] wr_feature_w =
          wr_feature_i[macro_row*FEATURE_IDX_W +: FEATURE_IDX_W];
      wire [GROUP_IDX_W-1:0] wr_group_w = wr_feature_w >> GROUP_ADDR_W;
      for (macro_group = 0; macro_group < GROUPS;
           macro_group = macro_group + 1) begin : g_group
        localparam [GROUP_IDX_W-1:0] GROUP_ID = macro_group;
        // Per-row tagged writeback may arrive with row skew; its feature tag
        // independently chooses the correct group and offset for that row.
        wire wr_select_w = wr_valid_i[macro_row] && wr_group_w == GROUP_ID;
        wire rd_select_w = rd_en_i &&
            (rd_feature_i >> GROUP_ADDR_W) == GROUP_ID;
        asic_sram_256xwide #(.WIDTH(DATA_W)) u_mem (
          .clk(clk),
          .en_i(wr_select_w || rd_select_w),
          .wr_en_i(wr_select_w),
          .addr_i(wr_select_w ?
                  {{(8-GROUP_ADDR_W){1'b0}}, wr_feature_w[GROUP_ADDR_W-1:0]} :
                  {{(8-GROUP_ADDR_W){1'b0}}, rd_feature_i[GROUP_ADDR_W-1:0]}),
          .wr_data_i(wr_data_i[macro_row*DATA_W +: DATA_W]),
          .rd_data_o(macro_q_w[macro_row][macro_group])
        );
      end
    end
  endgenerate

  // Retain the read group tag across the synchronous SRAM latency so output data
  // is selected from the group addressed by rd_feature_i.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_valid_o <= 1'b0;
      rd_group_q <= {GROUP_IDX_W{1'b0}};
    end else if (clear_i) begin
      rd_valid_o <= 1'b0;
    end else begin
      rd_valid_o <= rd_en_i;
      if (rd_en_i) rd_group_q <= rd_feature_i >> GROUP_ADDR_W;
    end
  end

  // Reassemble one O_old[:,d] vector from the independent row macros.
  always @(*) begin
    rd_data_o = {ROWS*DATA_W{1'b0}};
    for (row = 0; row < ROWS; row = row + 1)
      rd_data_o[row*DATA_W +: DATA_W] = macro_q_w[row][rd_group_q];
  end
`else
  // FPGA storage keeps the same logical [row][feature] mapping and synchronous
  // read behavior so the compute pipeline is backend-independent.
  (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:ROWS-1][0:HEAD_DIM-1];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_valid_o <= 1'b0;
      rd_data_o <= {ROWS*DATA_W{1'b0}};
    end else if (clear_i) begin
      rd_valid_o <= 1'b0;
    end else begin
      rd_valid_o <= rd_en_i;
      // One feature request returns every row in the stripe; tagged right-edge
      // results can simultaneously update independent row locations.
      if (rd_en_i) begin
        for (row = 0; row < ROWS; row = row + 1)
          rd_data_o[row*DATA_W +: DATA_W] <= mem[row][rd_feature_i];
      end
      for (row = 0; row < ROWS; row = row + 1) begin
        if (wr_valid_i[row])
          mem[row][wr_feature_i[row*FEATURE_IDX_W +: FEATURE_IDX_W]] <=
              wr_data_i[row*DATA_W +: DATA_W];
      end
    end
  end
`endif

endmodule
