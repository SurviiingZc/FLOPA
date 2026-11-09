"""Raise only the nonfunctional watchdog bound for full-head N16384 replays."""

import subprocess
from pathlib import Path

from submit_replay import ROOT, sha, write


root = Path('/data/workspaces/zhangcheng/flash_attention')
source = ROOT / 'src/tb_paper_replay.sv'
before = "repeat (64'd3000000000) @(posedge clk);"
after = ("for (longint unsigned watchdog = 0; watchdog < 64'd12000000000; "
         "watchdog = watchdog + 1) @(posedge clk);")
text = source.read_text()
assert text.count(before) == 1
destination = ROOT / 'src/tb_paper_replay_long.sv'
destination.write_text(text.replace(before, after))
build = ROOT / 'replay_build_long'
build.mkdir(exist_ok=True)
command = ['vcs', '-full64', '-sverilog', '-timescale=1ns/1ps', '+define+ATTN_ASIC',
           '-f', 'filelists/asic_models.f', '-f', 'filelists/rtl.f', str(destination),
           '-top', 'tb_paper_replay', '-Mdir=' + str(build / 'csrc'),
           '-o', str(build / 'simv'), '-l', str(build / 'compile.log')]
with (build / 'compile_console.log').open('w') as log:
    subprocess.run(command, cwd=str(root / 'tb/sim'), stdout=log,
                   stderr=subprocess.STDOUT, check=True)
folder = ROOT / 'replay_smoke/d72_q33_kv65_h2'
command = [str(build / 'simv'), '+VECTOR_DIR=' + str(folder),
           '+RESULT=' + str(build / 'smoke.csv'), '+NQ=33', '+NKV=65', '+HEADS=2',
           '+DIM=72', '+SCORE_SCALE=00080001', '+OUT_SCALE=000f0001',
           '+CLK_PERIOD_NS=1.6', '+no_notifier', '+notimingcheck',
           '-l', str(build / 'smoke.log')]
with (build / 'smoke_console.log').open('w') as log:
    subprocess.run(command, cwd=str(build), stdout=log, stderr=subprocess.STDOUT, check=True)
assert '[PASS] tb_paper_replay' in (build / 'smoke.log').read_text()
assert sha(build / 'smoke.csv.observed.bin') == sha(folder / 'o.bin')
write(build / 'ready.json', {
    'status': 'pass_long_watchdog_build', 'functional_rtl_changed': False,
    'watchdog_cycles': 12000000000, 'source_sha256': sha(destination),
    'executable_sha256': sha(build / 'simv'), 'reference_smoke_cycles': 7757,
})
