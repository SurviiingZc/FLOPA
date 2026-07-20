`timescale 1ns/1ps

// 1024x16 single-port logical memory composed from eight 256x8 macros.
// Only the selected depth slice is enabled, limiting dynamic SRAM power.
module asic_sram_1024x16 (
  input             clk,
  input             en_i,
  input             wr_en_i,
  input      [9:0]  addr_i,
  input      [15:0] wr_data_i,
  output reg [15:0] rd_data_o
);

  wire [15:0] depth_q [0:3];
  reg [1:0] read_depth_q;

  genvar depth_idx;
  genvar byte_idx;
  // Address[9:8] selects one depth slice; two byte macros form each 16-bit word.
  generate
    for (depth_idx = 0; depth_idx < 4; depth_idx = depth_idx + 1) begin : g_depth
      localparam [1:0] DEPTH_SELECT = depth_idx;
      for (byte_idx = 0; byte_idx < 2; byte_idx = byte_idx + 1) begin : g_byte
        wire selected_w;
        wire [7:0] macro_q_w;

        assign selected_w = en_i && (addr_i[9:8] == DEPTH_SELECT);
        assign depth_q[depth_idx][byte_idx*8 +: 8] = macro_q_w;

        uhdsp_256x8m4s u_sram (
          .SLP(1'b0),
          .SD(1'b0),
          .CLK(clk),
          .CEB(!selected_w),
          .WEB(!(selected_w && wr_en_i)),
          .CEBM(1'b1),
          .WEBM(1'b1),
          .A(addr_i[7:0]),
          .D(wr_data_i[byte_idx*8 +: 8]),
          .BWEB(8'h00),
          .AM(8'h00),
          .DM(8'h00),
          .BWEBM(8'hff),
          .BIST(1'b0),
          .RTSEL(2'b01),
          .WTSEL(2'b00),
          .Q(macro_q_w)
        );
      end
    end
  endgenerate

  // Register the depth tag on a read so the output mux follows synchronous macro
  // data across consecutive requests that cross a 256-word boundary.
  always @(posedge clk) begin
    if (en_i && !wr_en_i) read_depth_q <= addr_i[9:8];
  end

  always @(*) begin
    case (read_depth_q)
      2'd0: rd_data_o = depth_q[0];
      2'd1: rd_data_o = depth_q[1];
      2'd2: rd_data_o = depth_q[2];
      default: rd_data_o = depth_q[3];
    endcase
  end

endmodule
