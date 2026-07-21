`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "tb_common.svh"

module tb_score_scale_pipe;
  `TB_FSDB_DUMP("tb_score_scale_pipe.fsdb", tb_score_scale_pipe)

  reg clk = 0;
  reg rst_n = 0;
  reg valid_i = 0;
  reg signed [31:0] data_i = 0;
  reg signed [15:0] scale_mant_i = 0;
  reg [5:0] shift_i = 0;
  wire valid_o;
  wire signed [15:0] data_o;
  integer seen = 0;
  integer errors = 0;

  // Observe the II=1 pipeline continuously while the stimulus is still being
  // issued; the first result returns before the final input token is launched.
  always @(negedge clk) begin
    if (rst_n && valid_o) begin
      case (seen)
        0: `TB_CHECK(data_o == 16'sd15, "score scale first token")
        1: `TB_CHECK(data_o == 16'sd3, "score scale adjacent token")
        2: `TB_CHECK(data_o == -16'sd3, "score scale bubble token")
        default: `TB_CHECK(data_o == 16'sd32767, "score scale saturation")
      endcase
      seen = seen + 1;
    end
  end

  score_scale_pipe dut (.*);
  always #5 clk = ~clk;
  `TB_TIMEOUT(100, "tb_score_scale_pipe")

  initial begin
    repeat (3) @(posedge clk); rst_n = 1;

    @(negedge clk);
    data_i = 32'sd10; scale_mant_i = 16'sd3; shift_i = 1; valid_i = 1;
    @(negedge clk);
    data_i = 32'sd5; scale_mant_i = 16'sd1; shift_i = 1;
    @(negedge clk); valid_i = 0;
    @(negedge clk);
    data_i = -32'sd5; scale_mant_i = 16'sd1; shift_i = 1; valid_i = 1;
    @(negedge clk);
    data_i = 32'sd32767; scale_mant_i = 16'sd32767; shift_i = 0;
    @(negedge clk); valid_i = 0;

    while (seen < 4)
      @(negedge clk);
    `TB_FINISH("tb_score_scale_pipe")
  end
endmodule
