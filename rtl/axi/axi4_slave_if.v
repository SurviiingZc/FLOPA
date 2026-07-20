`timescale 1ns/1ps
`include "attention_defines.vh"

// Minimal AXI4-Lite request joiner. AW and W may arrive independently; wr_fire_o
// pulses only after both halves have been captured. Read requests are single-entry.
module axi4_slave_if #(
  parameter ADDR_W = `ATTN_AXI_ADDR_W
)(
  input                  clk,
  input                  rst_n,
  input                  wr_block_i,
  input                  rd_block_i,

  input  [ADDR_W-1:0]    s_axi_awaddr,
  input                  s_axi_awvalid,
  output                 s_axi_awready,

  input  [31:0]          s_axi_wdata,
  input  [3:0]           s_axi_wstrb,
  input                  s_axi_wvalid,
  output                 s_axi_wready,

  input  [ADDR_W-1:0]    s_axi_araddr,
  input                  s_axi_arvalid,
  output                 s_axi_arready,

  output reg             wr_fire_o,
  output reg             rd_fire_o,
  output reg [ADDR_W-1:0] wr_addr_o,
  output reg [31:0]      wr_data_o,
  output reg [3:0]       wr_strb_o,
  output reg [ADDR_W-1:0] rd_addr_o
);

  reg aw_hold_q;
  reg w_hold_q;
  reg ar_hold_q;

  // Backpressure prevents overwriting either one-entry holding register.
  assign s_axi_awready = ~aw_hold_q & ~wr_block_i;
  assign s_axi_wready  = ~w_hold_q  & ~wr_block_i;
  assign s_axi_arready = ~ar_hold_q & ~rd_block_i;

  // Fire pulses transfer ownership to the register file and release held channels.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_hold_q <= 1'b0;
      w_hold_q  <= 1'b0;
      ar_hold_q <= 1'b0;
      wr_fire_o <= 1'b0;
      rd_fire_o <= 1'b0;
      wr_addr_o <= {ADDR_W{1'b0}};
      wr_data_o <= 32'd0;
      wr_strb_o <= 4'd0;
      rd_addr_o <= {ADDR_W{1'b0}};
    end else begin
      wr_fire_o <= 1'b0;
      rd_fire_o <= 1'b0;

      if (s_axi_awvalid && s_axi_awready) begin
        aw_hold_q <= 1'b1;
        wr_addr_o <= s_axi_awaddr;
      end

      if (s_axi_wvalid && s_axi_wready) begin
        w_hold_q <= 1'b1;
        wr_data_o <= s_axi_wdata;
        wr_strb_o <= s_axi_wstrb;
      end

      if (s_axi_arvalid && s_axi_arready) begin
        ar_hold_q <= 1'b1;
        rd_addr_o <= s_axi_araddr;
      end

      if ((aw_hold_q || (s_axi_awvalid && s_axi_awready)) &&
          (w_hold_q  || (s_axi_wvalid  && s_axi_wready))) begin
        wr_fire_o <= 1'b1;
        aw_hold_q <= 1'b0;
        w_hold_q  <= 1'b0;
      end

      if (ar_hold_q || (s_axi_arvalid && s_axi_arready)) begin
        rd_fire_o <= 1'b1;
        ar_hold_q <= 1'b0;
      end
    end
  end

endmodule
