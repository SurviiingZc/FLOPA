`timescale 1ns/1ps

// Tracks ownership of a two-bank producer/consumer buffer. Loading, consuming,
// and switching are explicit so DMA can overlap compute without overwriting data.
module pingpong_buffer (
  input        clk,
  input        rst_n,
  input        clear_i,
  input        load_commit_i,
  input        load_bank_i,
  input        consume_i,
  input        switch_i,
  output reg   active_bank_o,
  output       active_valid_o,
  output       next_valid_o,
  output reg [1:0] bank_valid_o,
  output reg   protocol_error_o
);

  assign active_valid_o = bank_valid_o[active_bank_o];
  assign next_valid_o = bank_valid_o[~active_bank_o];

  // Flag double-commit and switch-to-empty as protocol errors.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_bank_o <= 1'b0;
      bank_valid_o <= 2'b00;
      protocol_error_o <= 1'b0;
    end else if (clear_i) begin
      active_bank_o <= 1'b0;
      bank_valid_o <= 2'b00;
      protocol_error_o <= 1'b0;
    end else begin
      protocol_error_o <= 1'b0;
      if (load_commit_i) begin
        if (bank_valid_o[load_bank_i]) protocol_error_o <= 1'b1;
        bank_valid_o[load_bank_i] <= 1'b1;
      end
      if (consume_i) bank_valid_o[active_bank_o] <= 1'b0;
      if (switch_i) begin
        if (bank_valid_o[~active_bank_o]) active_bank_o <= ~active_bank_o;
        else protocol_error_o <= 1'b1;
      end
    end
  end

endmodule
