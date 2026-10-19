"""Launch one persistent, one-shot GPU-energy queue without creating an automation."""

import subprocess
from pathlib import Path


root = Path('/10T/zhangcheng/flopa_evaluation_20261018')
script = Path('/home/zhangcheng/DiT-FA/scripts/queue_gpu_energy.py')
with (root / 'gpu_energy_queue.log').open('ab') as log:
    process = subprocess.Popen(
        ['/home/zhangcheng/miniconda3/envs/dfot/bin/python', '-u', str(script)],
        cwd=script.parent, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True, close_fds=True,
    )
print('GPU_ENERGY_QUEUE_PID', process.pid)
