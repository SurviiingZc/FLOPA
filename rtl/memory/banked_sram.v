`timescale 1ns/1ps

// Multi-lane word memory composed from independently enabled banks. Input
// registering isolates wide control/data buses from the physical SRAM macros.
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

  // The physical backend is single-port: a write cycle suppresses the shared read.
  assign any_write_w = wr_en_q && (|wr_bank_en_q);

`ifdef ATTN_ASIC
  wire [BANKS*BANK_W-1:0] macro_rd_data_w;

`ifndef SYNTHESIS
  initial begin
    if (BANK_W % 8 != 0) $fatal(1, "banked_sram ASIC BANK_W must be byte aligned");
    if (ADDR_W > 10) $fatal(1, "banked_sram ASIC depth exceeds available wrapper");
    if (ADDR_W > 8 && BANK_W != 16)
      $fatal(1, "banked_sram deep ASIC wrapper requires BANK_W == 16");
  end
`endif

  genvar bank_idx;
  // Select the shallow 256-depth wrapper whenever possible; use depth composition
  // only for configurations whose address width exceeds eight bits.
  generate
    for (bank_idx = 0; bank_idx < BANKS; bank_idx = bank_idx + 1) begin : g_bank
      wire bank_write_w;
      wire bank_enable_w;
      wire [ADDR_W-1:0] bank_addr_w;

      assign bank_write_w = wr_en_q && wr_bank_en_q[bank_idx];
      // Non-selected banks keep enable low during partial writes for lower power.
      assign bank_enable_w = any_write_w ? bank_write_w : rd_en_q;
      assign bank_addr_w = bank_write_w ? wr_addr_q : rd_addr_q;

      if (ADDR_W <= 8) begin : g_shallow
        asic_sram_256xwide #(.WIDTH(BANK_W)) u_bank (
          .clk(clk),
          .en_i(bank_enable_w),
          .wr_en_i(bank_write_w),
          .addr_i({{(8-ADDR_W){1'b0}}, bank_addr_w}),
          .wr_data_i(wr_data_q[bank_idx*BANK_W +: BANK_W]),
          .rd_data_o(macro_rd_data_w[bank_idx*BANK_W +: BANK_W])
        );
      end else begin : g_deep
        asic_sram_1024x16 u_bank (
          .clk(clk),
          .en_i(bank_enable_w),
          .wr_en_i(bank_write_w),
          .addr_i({{(10-ADDR_W){1'b0}}, bank_addr_w}),
          .wr_data_i(wr_data_q[bank_idx*BANK_W +: BANK_W]),
          .rd_data_o(macro_rd_data_w[bank_idx*BANK_W +: BANK_W])
        );
      end
    end
  endgenerate

  assign rd_data_o = macro_rd_data_w;
`else
  (* ram_style = "ultra" *) reg [BANK_W-1:0] mem [0:BANKS-1][0:DEPTH-1];
  reg [BANKS*BANK_W-1:0] rd_data_q;
  integer bank_iter;

  assign rd_data_o = rd_data_q;

  // FPGA model preserves single-port arbitration and independent bank write masks.
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

  // Register request payloads and align rd_valid_o with returned memory data.
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
