`timescale 1ns/1ps
`include "tb_fsdb.svh"

module tb_axi4_master_write;
  `TB_FSDB_DUMP("tb_axi4_master_write.fsdb", tb_axi4_master_write)
  reg clk;
  reg rst_n;
  reg start_i;
  reg [31:0] base_addr_i;
  reg [15:0] beat_count_i;
  reg [7:0] burst_len_i;
  reg [127:0] data_i;
  reg data_valid_i;
  wire data_ready_o;
  wire busy_o;
  wire done_o;
  wire error_o;
  wire [31:0] m_axi_awaddr;
  wire [7:0] m_axi_awlen;
  wire [2:0] m_axi_awsize;
  wire [1:0] m_axi_awburst;
  wire m_axi_awvalid;
  reg m_axi_awready;
  wire [127:0] m_axi_wdata;
  wire [15:0] m_axi_wstrb;
  wire m_axi_wlast;
  wire m_axi_wvalid;
  reg m_axi_wready;
  reg [1:0] m_axi_bresp;
  reg m_axi_bvalid;
  wire m_axi_bready;
  integer aw_count;
  integer w_count;
  integer test_case;

  axi4_master_write dut (
    .clk(clk), .rst_n(rst_n), .start_i(start_i), .base_addr_i(base_addr_i),
    .beat_count_i(beat_count_i), .burst_len_i(burst_len_i), .data_i(data_i), .data_valid_i(data_valid_i),
    .data_ready_o(data_ready_o), .busy_o(busy_o), .done_o(done_o), .error_o(error_o),
    .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
    .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
    .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
    .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
  );

  always #5 clk = ~clk;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_axi_bvalid <= 1'b0;
      m_axi_bresp <= 2'b00;
    end else begin
      if (m_axi_bvalid && m_axi_bready) begin
        m_axi_bvalid <= 1'b0;
      end else if (m_axi_wvalid && m_axi_wready && m_axi_wlast) begin
        m_axi_bvalid <= 1'b1;
        m_axi_bresp <= 2'b00;
      end
    end
  end

  always @(posedge clk) begin
    if (rst_n && m_axi_awvalid && m_axi_awready) begin
      if (m_axi_awsize !== 3'd4) $fatal(1, "AWSIZE mismatch");
      if (m_axi_awburst !== 2'b01) $fatal(1, "AWBURST mismatch");
      if (test_case == 0) begin
        case (aw_count)
          0: if (m_axi_awaddr !== 32'h1000_0000 || m_axi_awlen !== 8'd1) $fatal(1, "burst0 mismatch");
          1: if (m_axi_awaddr !== 32'h1000_0020 || m_axi_awlen !== 8'd1) $fatal(1, "burst1 mismatch");
          2: if (m_axi_awaddr !== 32'h1000_0040 || m_axi_awlen !== 8'd0) $fatal(1, "burst2 mismatch");
          default: $fatal(1, "too many AW bursts");
        endcase
      end else begin
        case (aw_count)
          0: if (m_axi_awaddr !== 32'h1000_0ff0 || m_axi_awlen !== 8'd0) $fatal(1, "4KB burst0 mismatch");
          1: if (m_axi_awaddr !== 32'h1000_1000 || m_axi_awlen !== 8'd1) $fatal(1, "4KB burst1 mismatch");
          default: $fatal(1, "too many 4KB AW bursts");
        endcase
      end
      aw_count = aw_count + 1;
    end

    if (rst_n && m_axi_wvalid && m_axi_wready) begin
      w_count = w_count + 1;
      if (test_case == 0) begin
        if ((w_count == 2 || w_count == 4 || w_count == 5) && !m_axi_wlast) $fatal(1, "missing WLAST at beat %0d", w_count);
        if (!(w_count == 2 || w_count == 4 || w_count == 5) && m_axi_wlast) $fatal(1, "unexpected WLAST at beat %0d", w_count);
      end else begin
        if ((w_count == 1 || w_count == 3) && !m_axi_wlast) $fatal(1, "missing 4KB WLAST at beat %0d", w_count);
        if (!(w_count == 1 || w_count == 3) && m_axi_wlast) $fatal(1, "unexpected 4KB WLAST at beat %0d", w_count);
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_i <= 128'd0;
    end else if (data_ready_o && data_valid_i) begin
      data_i <= data_i + 128'd1;
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start_i = 1'b0;
    base_addr_i = 32'h1000_0000;
    beat_count_i = 16'd5;
    burst_len_i = 8'd2;
    data_valid_i = 1'b0;
    m_axi_awready = 1'b1;
    m_axi_wready = 1'b1;
    aw_count = 0;
    w_count = 0;
    test_case = 0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    start_i = 1'b1;
    data_valid_i = 1'b1;
    @(posedge clk);
    start_i = 1'b0;

    wait (done_o || error_o);
    #1;
    if (error_o) $fatal(1, "axi master reported error");
    if (!done_o) $fatal(1, "axi master did not finish");
    if (aw_count != 3) $fatal(1, "AW count mismatch: %0d", aw_count);
    if (w_count != 5) $fatal(1, "W count mismatch: %0d", w_count);

    repeat (2) @(posedge clk);
    test_case = 1;
    aw_count = 0;
    w_count = 0;
    base_addr_i = 32'h1000_0ff0;
    beat_count_i = 16'd3;
    burst_len_i = 8'd16;
    start_i = 1'b1;
    @(posedge clk);
    start_i = 1'b0;
    wait (done_o || error_o);
    #1;
    if (error_o || aw_count != 2 || w_count != 3)
      $fatal(1, "4KB split failed error=%b aw=%0d w=%0d",error_o,aw_count,w_count);

    $display("[PASS] tb_axi4_master_write");
    $finish;
  end
endmodule
