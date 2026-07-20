`timescale 1ns/1ps

// Width-composed 256-deep single-port memory. WIDTH must be a multiple of 8.
// CEB/WEB are active-low; inactive byte macros remain disabled to reduce power.
module asic_sram_256xwide #(
  parameter WIDTH = 256
)(
  input                  clk,
  input                  en_i,
  input                  wr_en_i,
  input      [7:0]       addr_i,
  input      [WIDTH-1:0] wr_data_i,
  output     [WIDTH-1:0] rd_data_o
);

  genvar byte_idx;
  // Compose arbitrary byte-aligned words from the characterized 256x8 macros.
  generate
    for (byte_idx = 0; byte_idx < WIDTH/8; byte_idx = byte_idx + 1) begin : g_byte
      uhdsp_256x8m4s u_sram (
        .SLP(1'b0),
        .SD(1'b0),
        .CLK(clk),
        .CEB(!en_i),
        .WEB(!(en_i && wr_en_i)),
        .CEBM(1'b1),
        .WEBM(1'b1),
        .A(addr_i),
        .D(wr_data_i[byte_idx*8 +: 8]),
        .BWEB(8'h00),
        .AM(8'h00),
        .DM(8'h00),
        .BWEBM(8'hff),
        .BIST(1'b0),
        .RTSEL(2'b01),
        .WTSEL(2'b00),
        .Q(rd_data_o[byte_idx*8 +: 8])
      );
    end
  endgenerate

endmodule
