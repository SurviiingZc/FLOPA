"""Resume the rejected GPU layer test using a contention-aware supervisor."""

import subprocess
import os
import signal
import time
from pathlib import Path


root = Path('/10T/zhangcheng/flopa_evaluation_20261018')
script = Path('/home/zhangcheng/DiT-FA/scripts/queue_layerstep_gpu.py')
previous = Path('/proc/627326/cmdline')
if previous.exists():
    command = previous.read_bytes().replace(b'\x00', b' ').decode()
    assert '/scripts/benchmark_layerstep.py --n 4096' in command
    os.kill(627326, signal.SIGTERM)
    time.sleep(0.5)
with (root / 'layerstep_gpu_retry_queue.log').open('ab') as log:
    process = subprocess.Popen([
        '/home/zhangcheng/miniconda3/envs/dfot/bin/python', '-u', str(script)],
        cwd=script.parent, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True, close_fds=True)
print('LAYERSTEP_GPU_SUPERVISOR_PID', process.pid)
