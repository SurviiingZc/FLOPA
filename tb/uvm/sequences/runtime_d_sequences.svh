`ifndef RUNTIME_D_SEQUENCES_SVH
`define RUNTIME_D_SEQUENCES_SVH

class fa_runtime_d_vseq extends fa_attention_base_vseq;
    `uvm_object_utils(fa_runtime_d_vseq)
    attention_scoreboard scoreboard;
    string scenario;

    function new(string name = "fa_runtime_d_vseq");
        super.new(name);
        scenario = "single";
    endfunction

    task pre_body();
        super.pre_body();
        if (!$cast(scoreboard, uvm_top.find("uvm_test_top.env.scoreboard")))
            `uvm_fatal("NOSB", "runtime sequence requires attention_scoreboard")
    endtask

    task wait_pv_count(longint unsigned target);
        for (int unsigned cycle = 0; cycle < 20000; cycle++) begin
            if (p_sequencer.status_vif.pv_tiles >= target)
                return;
            @(posedge p_sequencer.status_vif.clk);
        end
        `uvm_fatal("PV_TIMEOUT", $sformatf(
            "PV tiles=%0d expected >=%0d state=%0d head=%0d q=%0d kv=%0d",
            p_sequencer.status_vif.pv_tiles, target,
            p_sequencer.status_vif.debug_state, p_sequencer.status_vif.head_index,
            p_sequencer.status_vif.q_tile_index, p_sequencer.status_vif.kv_tile_index))
    endtask

    task finish_job(bit allow_sticky_error = 0);
        bit [31:0] status;
        bit [1:0] resp;
        for (int unsigned poll = 0; poll < 10000; poll++) begin
            axil_read(`ATTN_REG_STATUS, status, resp);
            if (resp != 0 || (status[2] && !allow_sticky_error))
                `uvm_fatal("JOB_STATUS", $sformatf("status=%08h resp=%0d", status, resp))
            if (status[1]) begin
                repeat (5) @(posedge p_sequencer.status_vif.clk);
                scoreboard.check_job();
                return;
            end
        end
        `uvm_fatal("JOB_TIMEOUT", "runtime job did not reach DONE")
    endtask

    // One elaborated DUT is reused. START invalidates cache ownership, therefore
    // all loads follow START. Serial producer pacing stresses real empty-bank
    // waits without making this functional test a performance benchmark.
    task run_job(bit inject_busy = 0);
        int unsigned q_count;
        int unsigned kv_count;
        int unsigned global_q;
        int unsigned global_kv;
        longint unsigned target_pv;
        bit [31:0] data;
        bit [1:0] resp;
        longint unsigned old_array_edges;
        longint unsigned old_norm_edges;
        prepare_tensor();
        scoreboard.begin_job();
        program_supported_job();
        start_supported_job();
        wait_for_state(`ATTN_STATE_LOAD_Q, 1000);
        if (inject_busy) begin
            axil_write_with_resp(`ATTN_REG_HEAD_DIM, 128, resp);
            if (resp != 0)
                `uvm_error("BUSY_SHADOW", "busy HEAD_DIM shadow write must return OKAY")
            axil_read(`ATTN_REG_HEAD_DIM, data, resp);
            if (resp != 0 || data != 128 ||
                p_sequencer.status_vif.active_d != cfg.head_dim)
                `uvm_error("BUSY_SNAPSHOT", "programmed d changed the active job snapshot")
            axil_write(`ATTN_REG_SCORE_SCALE, 32'h0010_0007);
            axil_write(`ATTN_REG_OUT_SCALE, 32'h000e_0003);
            if (p_sequencer.status_vif.active_score_scale != cfg.score_scale ||
                p_sequencer.status_vif.active_out_scale != cfg.out_scale)
                `uvm_error("BUSY_SCALE", "busy scale write changed active scale snapshot")
            axil_write_with_resp(`ATTN_REG_CONTROL, 1, resp);
            if (resp != 2)
                `uvm_error("BUSY_START", "busy START must return SLVERR")
        end
        q_count = (cfg.seq_q + 31) / 32;
        kv_count = (cfg.seq_kv + 31) / 32;
        global_q = 0;
        global_kv = 0;
        target_pv = p_sequencer.status_vif.pv_tiles;
        for (int unsigned head = 0; head < cfg.num_q_heads; head++) begin
            for (int unsigned qt = 0; qt < q_count; qt++) begin
                load_tensor_tile(FA_TILE_Q, global_q % 2, qt, head);
                for (int unsigned kt = 0; kt < kv_count; kt++) begin
                    load_kv_tile(global_kv % 2, kt, head);
                    target_pv++;
                    wait_pv_count(target_pv);
                    global_kv++;
                end
                global_q++;
            end
        end
        finish_job(inject_busy);
        repeat (20) @(posedge p_sequencer.status_vif.clk);
        old_array_edges = p_sequencer.status_vif.array_edges;
        old_norm_edges = p_sequencer.status_vif.norm_edges;
        repeat (20) @(posedge p_sequencer.status_vif.clk);
        if (p_sequencer.status_vif.array_edges != old_array_edges ||
            p_sequencer.status_vif.norm_edges != old_norm_edges)
            `uvm_error("ICG_IDLE", "array or normalizer clock kept toggling after job drain")
    endtask

    task soft_reset();
        axil_write(`ATTN_REG_CONTROL, 2);
        wait_for_state(`ATTN_STATE_IDLE, 1000);
        repeat (10) @(posedge p_sequencer.status_vif.clk);
    endtask

    task expect_bad_start(bit [31:0] control, string description);
        bit [31:0] status;
        bit [1:0] resp;
        longint unsigned old_qk;
        longint unsigned old_pv;
        longint unsigned old_loader;
        old_qk = p_sequencer.status_vif.qk_features;
        old_pv = p_sequencer.status_vif.pv_features;
        old_loader = p_sequencer.status_vif.loader_beats;
        axil_write_with_resp(`ATTN_REG_CONTROL, control, resp);
        if (resp != 2)
            `uvm_error("BAD_START", $sformatf("%s returned resp=%0d", description, resp))
        repeat (10) @(posedge p_sequencer.status_vif.clk);
        axil_read(`ATTN_REG_STATUS, status, resp);
        if (resp != 0 || !status[2] || status[0] ||
            old_qk != p_sequencer.status_vif.qk_features ||
            old_pv != p_sequencer.status_vif.pv_features ||
            old_loader != p_sequencer.status_vif.loader_beats)
            `uvm_error("BAD_START_EFFECT", $sformatf(
                "%s produced work or failed to set error, status=%08h", description, status))
        soft_reset();
    endtask

    task control_cases();
        int unsigned illegal_d[3] = '{0, 129, 255};
        bit [31:0] data;
        bit [1:0] resp;
        foreach (illegal_d[index]) begin
            program_supported_job();
            axil_write(`ATTN_REG_HEAD_DIM, illegal_d[index]);
            expect_bad_start(1, $sformatf("illegal d=%0d", illegal_d[index]));
        end
        program_supported_job();
        expect_bad_start(32'h21, "legacy causal request");
        program_supported_job();
        expect_bad_start(32'h81, "legacy Decode request");
        program_supported_job();
        axil_write(`ATTN_REG_MODE, 32'hffff_ffff);
        axil_read(`ATTN_REG_MODE, data, resp);
        if (data != 0 || resp != 0)
            `uvm_error("RAZWI", "retired MODE must read zero")
        axil_write(`ATTN_REG_NUM_KV_HEADS, 255);
        axil_read(`ATTN_REG_NUM_KV_HEADS, data, resp);
        if (data != 0 || resp != 0)
            `uvm_error("RAZWI", "retired NUM_KV_HEADS must read zero")
        axil_write(`ATTN_REG_O_STRIDE, 255);
        axil_read(`ATTN_REG_O_STRIDE, data, resp);
        if (data != 0 || resp != 0)
            `uvm_error("RAZWI", "retired O_STRIDE must read zero")
        axil_read(32'h90, data, resp);
        if (data != `ATTN_HEAD_DIM || resp != 0)
            `uvm_error("MAX_D", "MAX_D capability read is incorrect")
        axil_write_with_resp(32'h90, 64, resp);
        if (resp != 2)
            `uvm_error("MAX_D", "MAX_D capability must be read-only")
        axil_read(`ATTN_REG_VERSION, data, resp);
        if (data != 32'h0003_0000 || resp != 0)
            `uvm_error("VERSION", "dense runtime-d ABI requires version 3")
        axil_read(`ATTN_REG_TILE_Q, data, resp);
        if (data != 32 || resp != 0)
            `uvm_error("TILE_RO", "tile capability must remain 32")
        axil_write_with_resp(`ATTN_REG_TILE_Q, 16, resp);
        if (resp != 2)
            `uvm_error("TILE_RO", "tile capability must be read-only")
        soft_reset();
        // Masked high bytes are not CONTROL requests. Disabled byte zero must
        // neither START nor interpret its legacy bits as an error.
        axil_write_with_resp(`ATTN_REG_CONTROL, 32'hffff_ff00, resp, 4'b0001);
        if (resp != 0)
            `uvm_error("CONTROL_WSTRB", "masked reserved high bytes were interpreted")
        axil_write_with_resp(`ATTN_REG_CONTROL, 32'h0000_00a1, resp, 4'b0000);
        if (resp != 0)
            `uvm_error("CONTROL_WSTRB", "zero-WSTRB CONTROL write must return OKAY")
        axil_read(`ATTN_REG_STATUS, data, resp);
        if (resp != 0 || data[2:0] != 0)
            `uvm_error("CONTROL_WSTRB", "disabled CONTROL byte zero changed state")
        cfg.head_dim = 72;
        cfg.seq_q = 3;
        cfg.seq_kv = 5;
        run_job(1);
        soft_reset();

        // Reset with a pending lower loader half, then reuse the same bank and
        // output path at another d. No completed-job exemption applies afterward.
        prepare_tensor();
        scoreboard.begin_job();
        program_supported_job();
        start_supported_job();
        wait_for_state(`ATTN_STATE_LOAD_Q, 1000);
        send_single_half(FA_TILE_Q, 0, 0, 256'hcafe, 0);
        scoreboard.abandon_reset_job();
        soft_reset();
        cfg.head_dim = 64;
        run_job();
        soft_reset();

        // Also abort an active QK pipeline, rather than only an unloaded job.
        cfg.head_dim = 128;
        prepare_tensor();
        scoreboard.begin_job();
        program_supported_job();
        start_supported_job();
        load_tensor_tile(FA_TILE_Q, 0, 0);
        load_kv_tile(0, 0);
        wait_for_state(`ATTN_STATE_QK, 1000);
        scoreboard.abandon_reset_job();
        soft_reset();
        cfg.head_dim = 72;
        run_job();
    endtask

    task body();
        int unsigned native_d[3] = '{64, 72, 128};
        int unsigned native_heads[3] = '{12, 16, 12};
        int unsigned switch_d[5] = '{64, 72, 128, 72, 64};
        int unsigned boundary_n[4] = '{31, 32, 33, 65};
        if (scenario == "switch") begin
            foreach (switch_d[index]) begin
                cfg.head_dim = switch_d[index];
                cfg.seq_q = (index % 2 == 0) ? 3 : 5;
                cfg.seq_kv = 5;
                cfg.num_q_heads = 2;
                run_job();
            end
        end else if (scenario == "range") begin
            for (int unsigned dim = 1; dim <= `ATTN_HEAD_DIM; dim++) begin
                cfg.head_dim = dim;
                cfg.seq_q = 1;
                cfg.seq_kv = 3;
                cfg.num_q_heads = 1;
                run_job();
            end
        end else if (scenario == "boundary") begin
            foreach (native_d[di]) begin
                foreach (boundary_n[ni]) begin
                    cfg.head_dim = native_d[di];
                    cfg.seq_q = boundary_n[ni];
                    cfg.seq_kv = boundary_n[ni];
                    cfg.num_q_heads = 1;
                    run_job();
                end
            end
        end else if (scenario == "multihead") begin
            foreach (native_d[index]) begin
                cfg.head_dim = native_d[index];
                cfg.num_q_heads = native_heads[index];
                cfg.seq_q = 3;
                cfg.seq_kv = 5;
                run_job();
            end
        end else if (scenario == "control") begin
            control_cases();
        end else if (scenario == "arith") begin
            cfg.seq_q = 3;
            cfg.seq_kv = 33;
            foreach (native_d[index]) begin
                cfg.head_dim = native_d[index];
                cfg.stimulus = FA_STIM_PWL_SEGMENTS;
                cfg.score_scale = 32'h0002_0005;
                run_job();
                cfg.stimulus = FA_STIM_RANDOM_FULL_RANGE;
                cfg.score_scale = 32'h0008_0001;
                run_job();
            end
        end else begin
            run_job();
        end
    endtask
endclass
`endif
