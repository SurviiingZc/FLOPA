`timescale 1ns/1ps

// Traffic-only reference: one 16-bit P tile spill and reload, using real RTL P data.
// No reference latency, area, or power result is inferred from this replay.
module tb_p_buffer_trace;
    reg clk = 0;
    reg enable = 0;
    reg write_enable = 0;
    reg [7:0] address = 0;
    reg [511:0] write_data = 0;
    wire [511:0] read_data;
    reg [511:0] expected [0:31];
    reg [511:0] parsed_data;
    integer handle, column, status, byte_index;
    longint unsigned tiles = 0;
    longint unsigned write_bytes = 0;
    longint unsigned read_bytes = 0;
    longint unsigned checked_words = 0;
    string filename;
    // Relaxed replay clock permits library output settling; only bytes are compared.
    always #5 clk = ~clk;

    asic_sram_256xwide #(.WIDTH(512)) u_probability_buffer (
        .clk(clk), .en_i(enable), .wr_en_i(write_enable), .addr_i(address),
        .wr_data_i(write_data), .rd_data_o(read_data)
    );

    // Count the physical 256x8 macro enables, independently of the driver.
    generate
        genvar lane;
        for (lane = 0; lane < 64; lane++) begin : g_port_counter
            always @(posedge clk) begin
                if (u_probability_buffer.g_byte[lane].u_sram.CEB === 1'b0) begin
                    if (u_probability_buffer.g_byte[lane].u_sram.WEB === 1'b0)
                        write_bytes++;
                    else if (u_probability_buffer.g_byte[lane].u_sram.WEB === 1'b1)
                        read_bytes++;
                    else
                        $fatal(1, "Unknown replay SRAM control");
                end
            end
        end
    endgenerate

    initial begin
        if (!$value$plusargs("P_TRACE=%s", filename))
            $fatal(1, "Missing P trace input");
        handle = $fopen(filename, "r");
        if (!handle) $fatal(1, "Cannot read P trace");
        repeat (2) @(negedge clk);
        status = $fscanf(handle, "%d %h\n", column, parsed_data);
        while (status == 2) begin
            for (integer index = 0; index < 32; index++) begin
                if (index != 0)
                    status = $fscanf(handle, "%d %h\n", column, parsed_data);
                if (status != 2 || column != 31 - index)
                    $fatal(1, "Bad replay input tile=%0d column=%0d", tiles, index);
                expected[column] = parsed_data;
                enable = 1;
                write_enable = 1;
                address = column;
                write_data = parsed_data;
                @(negedge clk);
            end
            for (integer index = 0; index < 32; index++) begin
                enable = 1;
                write_enable = 0;
                address = index;
                @(posedge clk);
                #4;
                if (read_data !== expected[index])
                    $fatal(1, "P SRAM readback mismatch tile=%0d column=%0d", tiles, index);
                checked_words++;
                @(negedge clk);
            end
            enable = 0;
            tiles++;
            status = $fscanf(handle, "%d %h\n", column, parsed_data);
        end
        if (!$feof(handle)) $fatal(1, "Malformed trailing P trace");
        $fclose(handle);
        $display("BUFFER_REPLAY,%0d,%0d,%0d,%0d",
                 tiles, checked_words, read_bytes, write_bytes);
        $display("[PASS] tb_p_buffer_trace");
        $finish;
    end
endmodule
