`timescale 1ns/1ps

// Pipelined piecewise-linear exp approximation for non-positive Q8 score deltas.
// The Q1.15 output represents probability/alpha in [0, 1].
module pwl_exp_unit (
  input                    clk,
  input                    rst_n,
  input                    valid_i,
  input signed [15:0]      x_i,
  output reg               valid_o,
  output reg [15:0]        y_o
);

  reg valid_s0_q;
  reg valid_s1_q;
  reg [15:0] base_s0_q;
  reg [15:0] endpoint_delta_s0_q;
  reg [7:0] fraction_s0_q;
  reg bypass_s0_q;
  reg [15:0] bypass_value_s0_q;
  reg [23:0] interpolation_s1_q;
  reg [15:0] base_s1_q;
  reg bypass_s1_q;
  reg [15:0] bypass_value_s1_q;
  wire [23:0] interpolation_product_w;

  reg [15:0] magnitude_w;
  reg [3:0] segment_w;
  reg [15:0] base_lo_w;
  reg [15:0] base_hi_w;
  reg bypass_w;
  reg [15:0] bypass_value_w;
  wire [31:0] interpolation_term_w = {8'd0, interpolation_s1_q} >> 8;
  wire [31:0] result_value_w = {16'd0, base_s1_q} - interpolation_term_w;

  fa_unsigned_mult_comb #(
    .A_W(16), .B_W(8)
  ) u_interpolation_multiplier (
    .a_i(endpoint_delta_s0_q), .b_i(fraction_s0_q),
    .product_o(interpolation_product_w)
  );

  // Stage 0 contains only absolute value, segment decode/table selection and the
  // 16-bit endpoint subtraction. Registering endpoint_delta_s0_q here is the
  // timing boundary immediately before the 16x8 interpolation multiplier.
  always @(*) begin
    magnitude_w = 16'd0;
    segment_w = 4'd0;
    base_lo_w = 16'd0;
    base_hi_w = 16'd0;
    bypass_w = 1'b0;
    bypass_value_w = 16'd0;
    if (x_i >= 0) begin
      bypass_w = 1'b1;
      bypass_value_w = 16'd32767;
    end else if (x_i <= -16'sd2048) begin
      bypass_w = 1'b1;
      bypass_value_w = 16'd0;
    end else begin
      magnitude_w = $unsigned(-$signed(x_i));
      segment_w = magnitude_w[11:8];
      case (segment_w)
        4'd0: begin base_lo_w = 16'd32767; base_hi_w = 16'd12055; end
        4'd1: begin base_lo_w = 16'd12055; base_hi_w = 16'd4435; end
        4'd2: begin base_lo_w = 16'd4435; base_hi_w = 16'd1632; end
        4'd3: begin base_lo_w = 16'd1632; base_hi_w = 16'd600; end
        4'd4: begin base_lo_w = 16'd600; base_hi_w = 16'd221; end
        4'd5: begin base_lo_w = 16'd221; base_hi_w = 16'd81; end
        4'd6: begin base_lo_w = 16'd81; base_hi_w = 16'd30; end
        default: begin base_lo_w = 16'd30; base_hi_w = 16'd11; end
      endcase
    end
  end

  // Two internal stages plus the output register accept one input every cycle.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s0_q <= 1'b0;
      valid_s1_q <= 1'b0;
      valid_o <= 1'b0;
    end else begin
      valid_s0_q <= valid_i;
      valid_s1_q <= valid_s0_q;
      valid_o <= valid_s1_q;
      if (valid_i) begin
        base_s0_q <= base_lo_w;
        endpoint_delta_s0_q <= base_lo_w - base_hi_w;
        fraction_s0_q <= magnitude_w[7:0];
        bypass_s0_q <= bypass_w;
        bypass_value_s0_q <= bypass_value_w;
      end
      if (valid_s0_q) begin
        // Isolated 16x8 stage; DesignWare/DSP mapping sees no decode or subtract
        // logic on the multiplier input path.
        interpolation_s1_q <= interpolation_product_w;
        base_s1_q <= base_s0_q;
        bypass_s1_q <= bypass_s0_q;
        bypass_value_s1_q <= bypass_value_s0_q;
      end
      if (valid_s1_q) begin
        if (bypass_s1_q)
          y_o <= bypass_value_s1_q;
        else if (result_value_w[31])
          y_o <= 16'd0;
        else if (result_value_w > 32'd32767)
          y_o <= 16'd32767;
        else
          y_o <= result_value_w[15:0];
      end
    end
  end

endmodule
