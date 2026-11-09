"""Launch one persistent, one-shot GPU-energy queue without creating an automation."""

import subprocess
import argparse
import os
import signal
import time
from pathlib import Path


root = Path('/10T/zhangcheng/flopa_evaluation_20261018')
script = Path('/home/zhangcheng/DiT-FA/scripts/queue_gpu_energy.py')
parser = argparse.ArgumentParser()
parser.add_argument('--replace-pid', type=int)
parser.add_argument('--allow-shared', action='store_true')
args = parser.parse_args()
previous = Path(f'/proc/{args.replace_pid}/cmdline') if args.replace_pid else None
if previous and previous.exists():
    command = previous.read_bytes().replace(b'\x00', b' ').decode()
    assert '/scripts/queue_gpu_energy.py' in command
    os.kill(args.replace_pid, signal.SIGTERM)
    time.sleep(0.5)
with (root / 'gpu_energy_queue.log').open('ab') as log:
    command = ['/home/zhangcheng/miniconda3/envs/dfot/bin/python', '-u', str(script)]
    if args.allow_shared:
        command.append('--allow-shared')
    process = subprocess.Popen(
        command,
        cwd=script.parent, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True, close_fds=True,
    )
print('GPU_ENERGY_QUEUE_PID', process.pid)
