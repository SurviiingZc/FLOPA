`timescale 1ns/1ps

module tb_perf_counter;
  reg clk;
  reg rst_n;
  reg clear_i;
  reg cycle_en_i;
  reg stall_i;
  reg mac_valid_i;
  reg tile_done_i;
  wire [63:0] cycle_count_o;
  wire [63:0] stall_count_o;
  wire [63:0] mac_count_o;
  wire [31:0] tile_count_o;

  perf_counter dut (
    .clk(clk),
    .rst_n(rst_n),
    .clear_i(clear_i),
    .cycle_en_i(cycle_en_i),
    .stall_i(stall_i),
    .mac_valid_i(mac_valid_i),
    .tile_done_i(tile_done_i),
    .cycle_count_o(cycle_count_o),
    .stall_count_o(stall_count_o),
    .mac_count_o(mac_count_o),
    .tile_count_o(tile_count_o)
  );

  always #5 clk = ~clk;

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    clear_i = 1'b0;
    cycle_en_i = 1'b0;
    stall_i = 1'b0;
    mac_valid_i = 1'b0;
    tile_done_i = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    repeat (2) @(posedge clk);
    cycle_en_i = 1'b1;

    stall_i = 1'b1; mac_valid_i = 1'b1; tile_done_i = 1'b0; @(posedge clk);
    stall_i = 1'b0; mac_valid_i = 1'b1; tile_done_i = 1'b1; @(posedge clk);
    stall_i = 1'b1; mac_valid_i = 1'b0; tile_done_i = 1'b0; @(posedge clk);
    stall_i = 1'b0; mac_valid_i = 1'b1; tile_done_i = 1'b1; @(posedge clk);
    stall_i = 1'b0; mac_valid_i = 1'b1; tile_done_i = 1'b0; @(posedge clk);
    cycle_en_i = 1'b0; stall_i = 1'b0; mac_valid_i = 1'b0; tile_done_i = 1'b0;
    #1;

    if (cycle_count_o != 64'd5) $fatal(1, "cycle_count mismatch: %0d", cycle_count_o);
    if (stall_count_o != 64'd2) $fatal(1, "stall_count mismatch: %0d", stall_count_o);
    if (mac_count_o != 64'd4096) $fatal(1, "mac_count mismatch: %0d", mac_count_o);
    if (tile_count_o != 32'd2) $fatal(1, "tile_count mismatch: %0d", tile_count_o);

    @(negedge clk);
    clear_i = 1'b1;
    @(posedge clk);
    #1;
    if (cycle_count_o != 64'd0 || stall_count_o != 64'd0 || mac_count_o != 64'd0 || tile_count_o != 32'd0) begin
      $fatal(1, "clear failed");
    end

    $display("[PASS] tb_perf_counter");
    $finish;
  end
endmodule
