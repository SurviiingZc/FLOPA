`timescale 1ns/1ps

// Leading-one normalization plus a 16-entry reciprocal seed LUT. The result is
// rescaled to the original unsigned 32-bit denominator for final O/l normalization.
module reciprocal_lut (
  input             clk,
  input             rst_n,
  input             valid_i,
  input      [31:0] value_i,
  output reg        valid_o,
  output reg [31:0] reciprocal_o
);

  integer bit_idx;
  reg valid_s0_q;
  reg [31:0] value_s0_q;
  reg valid_s1_q;
  reg found_s1_q;
  reg [5:0] msb_s1_q;
  reg [31:0] normalized_s1_q;
  reg [5:0] msb_w;
  reg found_w;
  reg [31:0] normalized_w;
  reg [15:0] seed_w;
  reg [63:0] shifted_w;

  // Find the denominator MSB, normalize it around bit 15, and restore the exponent
  // after the LUT lookup. A zero denominator maps to zero rather than infinity.
  always @(*) begin
    msb_w = 6'd0;
    found_w = 1'b0;
    for (bit_idx = 31; bit_idx >= 0; bit_idx = bit_idx - 1) begin
      if (!found_w && value_s0_q[bit_idx]) begin
        msb_w = bit_idx[5:0];
        found_w = 1'b1;
      end
    end
    if (!found_w)
      normalized_w = 32'd0;
    else if (msb_w >= 15)
      normalized_w = value_s0_q >> (msb_w - 15);
    else
      normalized_w = value_s0_q << (15 - msb_w);

    case (normalized_s1_q[14:11])
      4'h0: seed_w = 16'd32767;
      4'h1: seed_w = 16'd30840;
      4'h2: seed_w = 16'd29127;
      4'h3: seed_w = 16'd27594;
      4'h4: seed_w = 16'd26214;
      4'h5: seed_w = 16'd24966;
      4'h6: seed_w = 16'd23831;
      4'h7: seed_w = 16'd22795;
      4'h8: seed_w = 16'd21845;
      4'h9: seed_w = 16'd20972;
      4'ha: seed_w = 16'd20165;
      4'hb: seed_w = 16'd19418;
      4'hc: seed_w = 16'd18725;
      4'hd: seed_w = 16'd18079;
      4'he: seed_w = 16'd17476;
      default: seed_w = 16'd16913;
    endcase
    shifted_w = {48'd0, seed_w};
    if (!found_s1_q)
      shifted_w = 64'd0;
    else if (msb_s1_q > 15)
      shifted_w = {48'd0, seed_w} >> (msb_s1_q - 15);
    else
      shifted_w = {48'd0, seed_w} << (15 - msb_s1_q);
  end

  // Pipeline capture, normalization metadata, and saturated reciprocal output.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s0_q <= 1'b0;
      value_s0_q <= 32'd0;
      valid_s1_q <= 1'b0;
      found_s1_q <= 1'b0;
      msb_s1_q <= 6'd0;
      normalized_s1_q <= 32'd0;
      valid_o <= 1'b0;
      reciprocal_o <= 32'd0;
    end else begin
      valid_s0_q <= valid_i;
      if (valid_i)
        value_s0_q <= value_i;
      valid_s1_q <= valid_s0_q;
      if (valid_s0_q) begin
        found_s1_q <= found_w;
        msb_s1_q <= msb_w;
        normalized_s1_q <= normalized_w;
      end
      valid_o <= valid_s1_q;
      if (valid_s1_q)
        reciprocal_o <= (shifted_w[63:32] != 0) ?
            32'hffff_ffff : shifted_w[31:0];
    end
  end

endmodule
