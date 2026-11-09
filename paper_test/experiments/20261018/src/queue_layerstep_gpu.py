"""Retry only GPU-contention rejections; preserve other failures for diagnosis."""

import fcntl
import subprocess
import sys
import time
from pathlib import Path

from capture_trajectories import write_json


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
target = ROOT / 'baselines/layerstep_gpu'
target.mkdir(parents=True, exist_ok=True)
lock = (target / 'supervisor.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
for n in (1024, 4096):
    for attempt in range(1, 5761):
        path = target / f'queue_n{n}_attempt{attempt:04d}.log'
        write_json(target / 'queue_state.json', {'state': 'running_or_waiting_idle',
                                               'n': n, 'attempt': attempt, 'log': str(path)})
        with path.open('w') as log:
            process = subprocess.run([
                sys.executable, '-u', str(Path(__file__).with_name('benchmark_layerstep.py')),
                '--n', str(n),
            ], stdout=log, stderr=subprocess.STDOUT)
        if process.returncode == 0:
            break
        output = path.read_text()
        if 'GPU timing rejected due to another compute job' not in output:
            write_json(target / 'queue_state.json', {'state': 'failed', 'n': n,
                                                   'log': str(path)})
            raise RuntimeError('Layerstep GPU failure; inspect ' + str(path))
        write_json(target / 'queue_state.json', {'state': 'retry_after_external_contention',
                                               'n': n, 'log': str(path)})
        time.sleep(30)
    else:
        raise RuntimeError('Layerstep queue contention retry limit')
write_json(target / 'queue_state.json', {'state': 'complete', 'lengths': [1024, 4096]})
