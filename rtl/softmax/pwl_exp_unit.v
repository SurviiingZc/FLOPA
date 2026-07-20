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
  reg signed [15:0] x_s0_q;
  reg [15:0] y_s1_q;

  // Eight 1.0-wide segments use endpoint interpolation; positive inputs clamp to
  // one and sufficiently negative inputs clamp to zero.
  function [15:0] exp_pwl;
    input signed [15:0] x;
    reg [15:0] magnitude;
    reg [3:0] segment;
    reg [7:0] fraction;
    reg [15:0] base_lo;
    reg [15:0] base_hi;
    reg [31:0] interpolation;
    reg [31:0] result_value;
    begin
      if (x >= 0) begin
        exp_pwl = 16'd32767;
      end else if (x <= -16'sd2048) begin
        exp_pwl = 16'd0;
      end else begin
        magnitude = -x;
        segment = magnitude[11:8];
        fraction = magnitude[7:0];
        case (segment)
          4'd0: begin base_lo = 16'd32767; base_hi = 16'd12055; end
          4'd1: begin base_lo = 16'd12055; base_hi = 16'd4435; end
          4'd2: begin base_lo = 16'd4435; base_hi = 16'd1632; end
          4'd3: begin base_lo = 16'd1632; base_hi = 16'd600; end
          4'd4: begin base_lo = 16'd600; base_hi = 16'd221; end
          4'd5: begin base_lo = 16'd221; base_hi = 16'd81; end
          4'd6: begin base_lo = 16'd81; base_hi = 16'd30; end
          default: begin base_lo = 16'd30; base_hi = 16'd11; end
        endcase
        interpolation = {16'd0, (base_lo - base_hi)} * {24'd0, fraction};
        result_value = {16'd0, base_lo} - (interpolation >> 8);
        exp_pwl = result_value[15:0];
      end
    end
  endfunction

  // Two internal stages plus the output register accept one input every cycle.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s0_q <= 1'b0;
      valid_s1_q <= 1'b0;
      valid_o <= 1'b0;
      x_s0_q <= 16'sd0;
      y_s1_q <= 16'd0;
      y_o <= 16'd0;
    end else begin
      valid_s0_q <= valid_i;
      valid_s1_q <= valid_s0_q;
      valid_o <= valid_s1_q;
      if (valid_i) x_s0_q <= x_i;
      if (valid_s0_q) y_s1_q <= exp_pwl(x_s0_q);
      if (valid_s1_q) y_o <= y_s1_q;
    end
  end

endmodule
