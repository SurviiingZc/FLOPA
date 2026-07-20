`timescale 1ns/1ps

// Valid-qualified delay used to create systolic row/column skew. Data holds during
// bubbles while valid/last continue through every registered stage.
module fsa_delay_line #(
  parameter integer WIDTH = 16,
  parameter integer DEPTH = 1
)(
  input                  clk,
  input                  rst_n,
  input                  clear_i,
  input                  valid_i,
  input                  last_i,
  input      [WIDTH-1:0] data_i,
  output                 valid_o,
  output                 last_o,
  output     [WIDTH-1:0] data_o
);

  generate
    // DEPTH=0 keeps parameterized boundary wiring legal without adding latency.
    if (DEPTH == 0) begin : g_passthrough
      assign valid_o = valid_i;
      assign last_o = last_i && valid_i;
      assign data_o = data_i;
    end else begin : g_delay
      reg [DEPTH-1:0] valid_q;
      reg [DEPTH-1:0] last_q;
      reg [WIDTH-1:0] data_q [0:DEPTH-1];
      integer stage;

      assign valid_o = valid_q[DEPTH-1];
      assign last_o = last_q[DEPTH-1];
      assign data_o = data_q[DEPTH-1];

      // Shift payload only with valid to reduce unnecessary data-register toggles.
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          valid_q <= {DEPTH{1'b0}};
          last_q <= {DEPTH{1'b0}};
          for (stage = 0; stage < DEPTH; stage = stage + 1)
            data_q[stage] <= {WIDTH{1'b0}};
        end else if (clear_i) begin
          valid_q <= {DEPTH{1'b0}};
          last_q <= {DEPTH{1'b0}};
        end else begin
          valid_q[0] <= valid_i;
          last_q[0] <= valid_i && last_i;
          if (valid_i) data_q[0] <= data_i;
          for (stage = 1; stage < DEPTH; stage = stage + 1) begin
            valid_q[stage] <= valid_q[stage-1];
            last_q[stage] <= last_q[stage-1];
            if (valid_q[stage-1]) data_q[stage] <= data_q[stage-1];
          end
        end
      end
    end
  endgenerate

endmodule
