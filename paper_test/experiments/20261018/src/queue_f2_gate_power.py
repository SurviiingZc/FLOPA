"""Continue the approved F2 flow after synthesis and real calibration finish."""

import json
import subprocess
import sys
import time
from pathlib import Path

from submit_replay import ROOT, sha, write


root = Path('/data/workspaces/zhangcheng/flopa_eval_f2')
mapped = root / 'asic/dc/work/synth/tt/evaluation_f2/attention_accel_top/results'
build = root / 'paper_test/f2_gate_build'
build.mkdir(exist_ok=True)
for _ in range(48 * 60 * 2):
    if ((mapped / 'attention_accel_top_mapped.v').exists() and
            (ROOT / 'inputs/power_pixart_n256_s301/replay_manifest.json').exists()):
        break
    time.sleep(30)
else:
    raise RuntimeError('F2 synthesis or calibrated power input not available within 48h')
command = ['vcs', '-full64', '-sverilog', '-timescale=1ns/1ps', '-debug_access+all',
           '+incdir+../../rtl/common', '-f', 'filelists/asic_models.f',
           str(mapped / 'attention_accel_top_mapped.v'), str(ROOT / 'src/tb_paper_replay.sv'),
           '-top', 'tb_paper_replay', '-Mdir=' + str(build / 'csrc'),
           '-o', str(build / 'simv'), '-l', str(build / 'compile.log')]
with (build / 'compile_console.log').open('w') as log:
    subprocess.run(command, cwd=str(root / 'tb/sim'), stdout=log,
                   stderr=subprocess.STDOUT, check=True)
write(build / 'ready.json', {
    'status': 'gate_executable_compiled',
    'functional_verification': 'pending the complete byte-exact real N256 gate replay',
    'executable_sha256': sha(build / 'simv'),
    'netlist_sha256': sha(mapped / 'attention_accel_top_mapped.v'),
    'ddc_sha256': sha(mapped / 'attention_accel_top.ddc'),
    'testbench_sha256': sha(ROOT / 'src/tb_paper_replay.sv'),
    'git_commit': subprocess.check_output(
        ['git', '-C', str(root), 'rev-parse', 'HEAD'], universal_newlines=True).strip(),
})
subprocess.run([sys.executable, str(ROOT / 'src/run_power_job.py'), '--model', 'pixart',
                '--variant', 'F2'], check=True)
