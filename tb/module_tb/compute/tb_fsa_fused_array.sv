`timescale 1ns/1ps
`include "tb_fsdb.svh"
`include "attention_defines.vh"

module tb_fsa_fused_array;
  `TB_FSDB_DUMP("tb_fsa_fused_array.fsdb", tb_fsa_fused_array)

  localparam ROWS = 4;
  localparam COLS = 4;
  localparam DATA_W = 16;
  localparam SCORE_W = 32;
  localparam PROB_W = 16;
  localparam ACC_W = 32;
  localparam LSE_W = 32;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg clear_i = 1'b0;
  reg clear_rows_i = 1'b0;
  reg qk_clear_i = 1'b0;
  reg qk_valid_i = 1'b0;
  reg qk_last_i = 1'b0;
  reg [ROWS*DATA_W-1:0] qk_rows_i = 0;
  reg [COLS*DATA_W-1:0] qk_cols_i = 0;
  wire qk_last_o;
  reg softmax_start_i = 1'b0;
  reg [31:0] score_scale_i = 32'h0000_0100;
  reg [15:0] q_base_i = 0;
  reg [15:0] k_base_i = 0;
  reg [15:0] seq_q_i = ROWS;
  reg [15:0] seq_kv_i = COLS;
  reg causal_en_i = 1'b0;
  reg row_state_rd_en_i = 1'b0;
  reg [1:0] row_state_rd_row_i = 0;
  wire row_state_rd_valid_o;
  wire [PROB_W-1:0] row_state_alpha_o;
  wire [LSE_W-1:0] row_state_l_o;
  wire softmax_pv_ready_o;
  wire softmax_done_o;
  wire softmax_busy_o;
  reg pv_start_i = 1'b0;
  wire pv_ready_o;
  reg pv_seed_zero_i = 1'b1;
  reg pv_load_row_valid_i = 1'b0;
  reg [1:0] pv_load_row_index_i = 0;
  reg pv_load_row_half_i = 1'b0;
  reg [COLS*ACC_W-1:0] pv_load_row_data_i = 0;
  reg pv_valid_i = 1'b0;
  reg pv_issue_half_i = 1'b0;
  reg pv_half_last_i = 1'b0;
  reg [COLS*DATA_W-1:0] pv_cols_i = 0;
  wire pv_done_o;
  wire row_valid_o;
  reg row_ready_i = 1'b1;
  wire [1:0] row_index_o;
  wire row_half_o;
  wire [COLS*ACC_W-1:0] row_data_o;
  wire error_o;

  integer row;
  integer col;
  integer key;
  integer rows_seen;
  integer errors;
  integer expected_delta_col;
  integer expected_prob_col;
  integer delta_cols_seen;
  integer prob_cols_seen;
  reg saw_sum_overlap;
  reg saw_pv_ready_before_done;
  reg signed [31:0] observed;
  reg [15:0] expected_prob [0:COLS-1];
  reg [31:0] expected_causal_l [0:ROWS-1];

  fsa_fused_array #(
    .ROWS(ROWS), .COLS(COLS), .DATA_W(DATA_W), .SCORE_W(SCORE_W),
    .PROB_W(PROB_W), .ACC_W(ACC_W), .LSE_W(LSE_W)
  ) dut (.*);

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst_n) begin
      if (softmax_start_i) begin
        expected_delta_col = COLS - 1;
        expected_prob_col = COLS - 1;
        delta_cols_seen = 0;
        prob_cols_seen = 0;
        saw_sum_overlap = 1'b0;
        saw_pv_ready_before_done = 1'b0;
      end
      if (dut.delta_col_valid_w) begin
        if (dut.delta_col_index_w !== expected_delta_col[1:0]) begin
          $error("[FAIL] delta column order got=%0d expected=%0d",
                 dut.delta_col_index_w, expected_delta_col);
          errors = errors + 1;
        end
        expected_delta_col = expected_delta_col - 1;
        delta_cols_seen = delta_cols_seen + 1;
      end
      if (dut.prob_write_valid_w) begin
        if (dut.prob_write_col_w !== expected_prob_col[1:0]) begin
          $error("[FAIL] probability column order got=%0d expected=%0d",
                 dut.prob_write_col_w, expected_prob_col);
          errors = errors + 1;
        end
        expected_prob_col = expected_prob_col - 1;
        prob_cols_seen = prob_cols_seen + 1;
      end
      if (|dut.sum_launch_rows_q && prob_cols_seen < COLS)
        saw_sum_overlap = 1'b1;
      if (softmax_pv_ready_o && !softmax_done_o)
        saw_pv_ready_before_done = 1'b1;
      if (softmax_done_o) begin
        if (delta_cols_seen != COLS || prob_cols_seen != COLS ||
            !saw_sum_overlap || !saw_pv_ready_before_done) begin
          $error("[FAIL] column stream delta=%0d prob=%0d sum_overlap=%b pv_ready=%b",
                 delta_cols_seen, prob_cols_seen, saw_sum_overlap,
                 saw_pv_ready_before_done);
          errors = errors + 1;
        end
      end
    end
  end

  task check_row_state;
    input [1:0] check_row;
    input [PROB_W-1:0] expected_alpha;
    input [LSE_W-1:0] expected_l;
    begin
      @(negedge clk);
      row_state_rd_en_i = 1'b1;
      row_state_rd_row_i = check_row;
      @(negedge clk);
      row_state_rd_en_i = 1'b0;
      #1;
      if (!row_state_rd_valid_o || row_state_alpha_o !== expected_alpha ||
          row_state_l_o !== expected_l) begin
        $error("[FAIL] row_state row=%0d valid=%b alpha=%0d/%0d l=%0d/%0d",
               check_row, row_state_rd_valid_o, row_state_alpha_o,
               expected_alpha, row_state_l_o, expected_l);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    expected_prob[0] = 16'd1632;
    expected_prob[1] = 16'd4435;
    expected_prob[2] = 16'd12055;
    expected_prob[3] = 16'd32767;
    expected_causal_l[0] = 32'd32767;
    expected_causal_l[1] = 32'd44822;
    expected_causal_l[2] = 32'd49257;
    expected_causal_l[3] = 32'd50889;
    errors = 0;
    rows_seen = 0;
    expected_delta_col = COLS - 1;
    expected_prob_col = COLS - 1;
    delta_cols_seen = 0;
    prob_cols_seen = 0;
    saw_sum_overlap = 1'b0;
    saw_pv_ready_before_done = 1'b0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    @(negedge clk);
    qk_clear_i = 1'b1;
    clear_rows_i = 1'b1;
    @(negedge clk);
    qk_clear_i = 1'b0;
    clear_rows_i = 1'b0;
    for (row = 0; row < ROWS; row = row + 1)
      qk_rows_i[row*DATA_W +: DATA_W] = 16'sd1;
    for (col = 0; col < COLS; col = col + 1)
      qk_cols_i[col*DATA_W +: DATA_W] = col + 1;
    qk_valid_i = 1'b1;
    qk_last_i = 1'b1;
    @(negedge clk);
    qk_valid_i = 1'b0;
    qk_last_i = 1'b0;

    wait (qk_last_o);
    @(negedge clk);
    softmax_start_i = 1'b1;
    @(negedge clk);
    softmax_start_i = 1'b0;
    wait (softmax_done_o);
    #1;
    for (row = 0; row < ROWS; row = row + 1)
      check_row_state(row[1:0], 16'd0, 32'd50889);

    @(negedge clk);
    pv_start_i = 1'b1;
    @(negedge clk);
    pv_start_i = 1'b0;
    wait (pv_ready_o);

    for (key = 0; key < 2*COLS; key = key + 1) begin
      @(negedge clk);
      pv_cols_i = {COLS*DATA_W{1'b0}};
      for (col = 0; col < COLS; col = col + 1)
        pv_cols_i[col*DATA_W +: DATA_W] =
            (col == (key % COLS)) ? 16'sd1 : 16'sd0;
      pv_valid_i = 1'b1;
      pv_issue_half_i = (key >= COLS);
      pv_half_last_i = (key == COLS-1) || (key == 2*COLS-1);
    end
    @(negedge clk);
    pv_valid_i = 1'b0;
    pv_issue_half_i = 1'b0;
    pv_half_last_i = 1'b0;

    while (rows_seen < 2*ROWS) begin
      @(negedge clk);
      if (row_valid_o) begin
        if (row_index_o !== rows_seen[1:0] ||
            row_half_o !== (rows_seen >= ROWS)) begin
          $error("[FAIL] row order got=(half%0d,row%0d) expected=(half%0d,row%0d)",
                 row_half_o, row_index_o, rows_seen >= ROWS, rows_seen % ROWS);
          errors = errors + 1;
        end
        for (col = 0; col < COLS; col = col + 1) begin
          observed = row_data_o[col*ACC_W +: ACC_W];
          if (observed !== expected_prob[col]) begin
            $error("[FAIL] PV half=%0d row=%0d col=%0d got=%0d expected=%0d",
                   row_half_o, row_index_o, col, observed, expected_prob[col]);
            errors = errors + 1;
          end
        end
        rows_seen = rows_seen + 1;
      end
    end

    wait (pv_done_o);

    @(negedge clk);
    qk_clear_i = 1'b1;
    clear_rows_i = 1'b1;
    causal_en_i = 1'b1;
    @(negedge clk);
    qk_clear_i = 1'b0;
    clear_rows_i = 1'b0;
    qk_valid_i = 1'b1;
    qk_last_i = 1'b1;
    @(negedge clk);
    qk_valid_i = 1'b0;
    qk_last_i = 1'b0;
    wait (qk_last_o);
    @(negedge clk);
    softmax_start_i = 1'b1;
    @(negedge clk);
    softmax_start_i = 1'b0;
    wait (softmax_done_o);
    #1;
    for (row = 0; row < ROWS; row = row + 1)
      check_row_state(row[1:0], 16'd0, expected_causal_l[row]);

    if (softmax_busy_o || error_o) begin
      $error("[FAIL] unexpected status busy=%b error=%b", softmax_busy_o, error_o);
      errors = errors + 1;
    end
    if (errors == 0) $display("[PASS] tb_fsa_fused_array");
    else $fatal(1, "tb_fsa_fused_array failed errors=%0d", errors);
    $finish;
  end

  initial begin
    repeat (1200) @(posedge clk);
    $fatal(1, "tb_fsa_fused_array timeout");
  end

endmodule
