`timescale 1ns/1ps

module banked_sram #(
  parameter BANKS = 16,
  parameter BANK_W = 16,
  parameter ADDR_W = 10,
  parameter DEPTH = (1 << ADDR_W)
)(
  input                         clk,
  input                         rst_n,
  input                         wr_en_i,
  input      [ADDR_W-1:0]       wr_addr_i,
  input      [BANKS*BANK_W-1:0] wr_data_i,
  input      [BANKS-1:0]        wr_bank_en_i,
  input                         rd_en_i,
  input      [ADDR_W-1:0]       rd_addr_i,
  output     [BANKS*BANK_W-1:0] rd_data_o,
  output reg                    rd_valid_o
);

  reg wr_en_q;
  reg [ADDR_W-1:0] wr_addr_q;
  reg [BANKS*BANK_W-1:0] wr_data_q;
  reg [BANKS-1:0] wr_bank_en_q;
  reg rd_en_q;
  reg [ADDR_W-1:0] rd_addr_q;
  wire any_write_w;

  assign any_write_w = wr_en_q && (|wr_bank_en_q);

`ifdef ATTN_ASIC
  wire [BANKS*BANK_W-1:0] macro_rd_data_w;

  genvar bank_idx;
  generate
    for (bank_idx = 0; bank_idx < BANKS; bank_idx = bank_idx + 1) begin : g_bank
      wire bank_write_w;
      wire bank_enable_w;
      wire [ADDR_W-1:0] bank_addr_w;

      assign bank_write_w = wr_en_q && wr_bank_en_q[bank_idx];
      assign bank_enable_w = any_write_w ? bank_write_w : rd_en_q;
      assign bank_addr_w = bank_write_w ? wr_addr_q : rd_addr_q;

      asic_sram_1024x16 u_bank (
        .clk(clk),
        .en_i(bank_enable_w),
        .wr_en_i(bank_write_w),
        .addr_i(bank_addr_w[9:0]),
        .wr_data_i(wr_data_q[bank_idx*BANK_W +: BANK_W]),
        .rd_data_o(macro_rd_data_w[bank_idx*BANK_W +: BANK_W])
      );
    end
  endgenerate

  assign rd_data_o = macro_rd_data_w;
`else
  (* ram_style = "ultra" *) reg [BANK_W-1:0] mem [0:BANKS-1][0:DEPTH-1];
  reg [BANKS*BANK_W-1:0] rd_data_q;
  integer bank_iter;

  assign rd_data_o = rd_data_q;

  always @(posedge clk) begin
    if (any_write_w) begin
      for (bank_iter = 0; bank_iter < BANKS; bank_iter = bank_iter + 1) begin
        if (wr_bank_en_q[bank_iter]) begin
          mem[bank_iter][wr_addr_q] <= wr_data_q[bank_iter*BANK_W +: BANK_W];
        end
      end
    end else if (rd_en_q) begin
      for (bank_iter = 0; bank_iter < BANKS; bank_iter = bank_iter + 1) begin
        rd_data_q[bank_iter*BANK_W +: BANK_W] <= mem[bank_iter][rd_addr_q];
      end
    end
  end
`endif

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_en_q <= 1'b0;
      wr_addr_q <= {ADDR_W{1'b0}};
      wr_data_q <= {(BANKS*BANK_W){1'b0}};
      wr_bank_en_q <= {BANKS{1'b0}};
      rd_en_q <= 1'b0;
      rd_addr_q <= {ADDR_W{1'b0}};
      rd_valid_o <= 1'b0;
    end else begin
      wr_en_q <= wr_en_i;
      rd_en_q <= rd_en_i;
      rd_valid_o <= rd_en_q && !any_write_w;

      if (wr_en_i) begin
        wr_addr_q <= wr_addr_i;
        wr_data_q <= wr_data_i;
        wr_bank_en_q <= wr_bank_en_i;
      end
      if (rd_en_i) begin
        rd_addr_q <= rd_addr_i;
      end
    end
  end

endmodule
