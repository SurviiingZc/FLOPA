`timescale 1ns/1ps
`include "attention_defines.vh"

// AXI4 write-only burst engine for normalized output. Bursts are split at both
// the configured maximum length and mandatory 4-KB address boundaries.
module axi4_master_write #(
  parameter ADDR_W = `ATTN_AXI_ADDR_W,
  parameter DATA_W = `ATTN_AXI_DATA_W
)(
  input                  clk,
  input                  rst_n,
  input                  start_i,
  input  [ADDR_W-1:0]    base_addr_i,
  input  [15:0]          beat_count_i,
  input  [7:0]           burst_len_i,
  input  [DATA_W-1:0]    data_i,
  input                  data_valid_i,
  output                 data_ready_o,
  output reg             busy_o,
  output reg             done_o,
  output reg             error_o,

  output reg [ADDR_W-1:0] m_axi_awaddr,
  output reg [7:0]        m_axi_awlen,
  output reg [2:0]        m_axi_awsize,
  output reg [1:0]        m_axi_awburst,
  output reg              m_axi_awvalid,
  input                   m_axi_awready,

  output [DATA_W-1:0]     m_axi_wdata,
  output [(DATA_W/8)-1:0] m_axi_wstrb,
  output                  m_axi_wlast,
  output                  m_axi_wvalid,
  input                   m_axi_wready,

  input  [1:0]            m_axi_bresp,
  input                   m_axi_bvalid,
  output reg              m_axi_bready
);

  localparam ST_IDLE  = 3'd0;
  localparam ST_AW    = 3'd1;
  localparam ST_W     = 3'd2;
  localparam ST_B     = 3'd3;
  localparam ST_DONE  = 3'd4;
  localparam ST_ERROR = 3'd5;
  localparam [ADDR_W-1:0] BYTES_PER_BEAT = DATA_W / 8;

  reg [2:0] state_q;
  reg [15:0] beats_left_q;
  reg [7:0] burst_left_q;
  reg [ADDR_W-1:0] addr_q;
  reg [7:0] burst_size_q;
  reg [8:0] beats_to_4k_w;
  reg [12:0] beats_to_4k_full_w;
  reg [15:0] burst_size_full_w;
  reg [7:0] burst_size_next_w;

  // The source advances only on a real W-channel handshake.
  assign data_ready_o = (state_q == ST_W) && m_axi_wready;
  assign m_axi_wvalid = (state_q == ST_W) && data_valid_i;
  assign m_axi_wdata = data_i;
  assign m_axi_wstrb = {(DATA_W/8){1'b1}};
  assign m_axi_wlast = (state_q == ST_W) && (burst_left_q == 8'd1);

  // Select the next burst as min(beats left, configured burst, 4-KB remainder).
  always @(*) begin
    beats_to_4k_full_w = (13'd4096 - {1'b0, addr_q[11:0]}) >> 4;
    beats_to_4k_w = beats_to_4k_full_w[8:0];
    burst_size_full_w = beats_left_q;
    if (burst_size_full_w > {8'd0, burst_len_i})
      burst_size_full_w = {8'd0, burst_len_i};
    if (burst_size_full_w > {7'd0, beats_to_4k_w})
      burst_size_full_w = {7'd0, beats_to_4k_w};
    burst_size_next_w = burst_size_full_w[7:0];
  end

  // One outstanding burst is allowed: AW -> streamed W beats -> B response.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      busy_o <= 1'b0;
      done_o <= 1'b0;
      error_o <= 1'b0;
      beats_left_q <= 16'd0;
      burst_left_q <= 8'd0;
      addr_q <= {ADDR_W{1'b0}};
      burst_size_q <= 8'd0;
      m_axi_awaddr <= {ADDR_W{1'b0}};
      m_axi_awlen <= 8'd0;
      m_axi_awsize <= 3'd4;
      m_axi_awburst <= 2'b01;
      m_axi_awvalid <= 1'b0;
      m_axi_bready <= 1'b0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          done_o <= 1'b0;
          error_o <= 1'b0;
          busy_o <= 1'b0;
          m_axi_awvalid <= 1'b0;
          m_axi_bready <= 1'b0;
          if (start_i) begin
            if (beat_count_i == 16'd0 || burst_len_i == 8'd0 ||
                base_addr_i[3:0] != 4'd0) begin
              error_o <= 1'b1;
              state_q <= ST_ERROR;
            end else begin
              busy_o <= 1'b1;
              beats_left_q <= beat_count_i;
              addr_q <= base_addr_i;
              state_q <= ST_AW;
            end
          end
        end

        ST_AW: begin
          busy_o <= 1'b1;
          m_axi_bready <= 1'b0;
          burst_size_q <= burst_size_next_w;
          m_axi_awaddr <= addr_q;
          m_axi_awlen <= burst_size_next_w - 8'd1;
          m_axi_awsize <= 3'd4;
          m_axi_awburst <= 2'b01;
          m_axi_awvalid <= 1'b1;
          if (m_axi_awvalid && m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
            burst_left_q <= burst_size_q;
            state_q <= ST_W;
          end
        end

        ST_W: begin
          busy_o <= 1'b1;
          if (m_axi_wvalid && m_axi_wready) begin
            burst_left_q <= burst_left_q - 8'd1;
            beats_left_q <= beats_left_q - 16'd1;
            if (burst_left_q == 8'd1) begin
              state_q <= ST_B;
              m_axi_bready <= 1'b1;
            end
          end
        end

        ST_B: begin
          busy_o <= 1'b1;
          m_axi_bready <= 1'b1;
          if (m_axi_bvalid && m_axi_bready) begin
            m_axi_bready <= 1'b0;
            if (m_axi_bresp != 2'b00) begin
              error_o <= 1'b1;
              state_q <= ST_ERROR;
            end else if (beats_left_q == 16'd0) begin
              done_o <= 1'b1;
              busy_o <= 1'b0;
              state_q <= ST_DONE;
            end else begin
              addr_q <= addr_q +
                  ({{(ADDR_W-8){1'b0}}, burst_size_q} * BYTES_PER_BEAT);
              state_q <= ST_AW;
            end
          end
        end

        ST_DONE: begin
          busy_o <= 1'b0;
          done_o <= 1'b1;
          state_q <= ST_IDLE;
        end

        ST_ERROR: begin
          busy_o <= 1'b0;
          done_o <= 1'b0;
          error_o <= 1'b1;
          m_axi_awvalid <= 1'b0;
          m_axi_bready <= 1'b0;
          if (start_i) begin
            error_o <= 1'b0;
            state_q <= ST_IDLE;
          end
        end

        default: begin
          state_q <= ST_ERROR;
          error_o <= 1'b1;
        end
      endcase
    end
  end

endmodule
